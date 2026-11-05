#!/usr/bin/env bash
# Build one combined Access file and one combined Account file from every EPAS cluster in
# config/sources.conf. Runs on the central server, from cron, e.g.:
#
#   30 1 * * * /opt/edb-sailpoint-feeds/scripts/collect_all.sh >> /var/log/sailpoint_feeds.log 2>&1
#
#   1. Per cluster: classify every login from pg_hba.conf, check for problems, and read the
#      AD settings (server, branch, bind account) of each AD login's pg_hba.conf line.
#   2. One AD lookup per distinct AD profile (server + branch + bind account + search rule).
#   3. Per cluster: load its AD rows into a temporary table and extract both feeds.
#   4. Combine the files (header once) and publish them atomically.
#
# Runs are independent: if any cluster or AD lookup fails, NOTHING is published and the
# files already in OUTPUT_DIR are left as they are. Nothing from earlier runs is ever used.
# Nothing is stored in the clusters: the SQL in sql/feed uses temporary tables and views only.
#
# Exit codes: 0 = both files published, 2 = failed (nothing published).
# Also writes STATUS_FILE (JSON) and, if MAIL_TO is set, can send an email.
set -uo pipefail
LOG_NAME="collect_all"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_sources
SQL_DIR="$REPO_DIR/sql/feed"

[ -n "${OUTPUT_DIR:-}" ] || die "OUTPUT_DIR is not set in $CENTRAL_ENV"
mkdir -p "$STATE_DIR/runs" "$STATE_DIR/archive" "$OUTPUT_DIR" || die "cannot create $STATE_DIR or $OUTPUT_DIR"

# Only one run at a time.
exec 9> "$STATE_DIR/collect_all.lock"
flock -n 9 || die "another run is still active"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"           # logs only: kept KEEP_DAYS
mkdir -p "$RUN_DIR/ad"
# Private work folder: AD bind passwords, AD names, per-cluster extracts. Deleted on exit.
PRIV="$(umask 077; mktemp -d)"
trap 'rm -rf "$PRIV"' EXIT
log "start run $RUN_ID: ${#SRC_CODE[@]} clusters"

PSQL_VARS=(-v "person_ou=$PERSON_OU" -v "nonperson_ou=$NONPERSON_OU")

# Run function $1 for each remaining argument, at most PARALLEL at a time.
run_parallel() {
    local fn="$1" x; shift
    for x in "$@"; do
        "$fn" "$x" &
        while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n; done
    done
    wait
}

# First meaningful error line of a log.
first_error() {
    grep -m1 -E 'ERROR|FATAL|error|could not|Can.t' "$1" 2>/dev/null \
        | sed -E -e 's/^psql:[^ ]* //' -e 's/^ERROR: +//' | cut -c1-300
}

# ---- 1. Classify logins, check, read AD settings per cluster ---------------------------
pass1() {
    local i="$1" code="${SRC_CODE[$1]}"
    mkdir -p "$RUN_DIR/$code"
    pg_src "$i" "${PSQL_VARS[@]}" -v "source_code=$code" > "$RUN_DIR/$code/pass1.log" 2>&1 <<SQL || touch "$RUN_DIR/$code/failed"
\i '$SQL_DIR/00_prepare.sql'
\i '$SQL_DIR/10_base.sql'
\i '$SQL_DIR/20_checks.sql'
\i '$SQL_DIR/15_ldap_logins.sql'
\copy (SELECT login, server, port, scheme, tls, basedn, binddn, bindpasswd, searchattribute, searchfilter FROM ldap_logins ORDER BY login) TO '$PRIV/$code.ldap' WITH (FORMAT csv, DELIMITER E'\x1f', QUOTE E'\x02')
SQL
}
run_parallel pass1 "${!SRC_CODE[@]}"

ANY_FAILED=0
for c in "${SRC_CODE[@]}"; do [ -e "$RUN_DIR/$c/failed" ] && ANY_FAILED=1; done

# ---- 2. Group AD logins into profiles; one lookup per profile ---------------------------
# Skipped if a cluster already failed: nothing would be published anyway.
declare -A PROFILE_LABEL=()
for c in "${SRC_CODE[@]}"; do
    [ "$ANY_FAILED" -eq 0 ] || break
    : > "$PRIV/$c.map"
    while IFS=$'\x1f' read -r login server port scheme tls basedn binddn pw attr filter; do
        [ -n "$login" ] || continue
        key="$server"$'\x1f'"$port"$'\x1f'"$scheme"$'\x1f'"$tls"$'\x1f'"$basedn"$'\x1f'"$binddn"$'\x1f'"$pw"$'\x1f'"$attr"$'\x1f'"$filter"
        id="$(printf '%s' "$key" | sha256sum | cut -c1-12)"
        if [ -z "${PROFILE_LABEL[$id]:-}" ]; then
            mkdir -p "$PRIV/profiles/$id"
            printf '%s\n' "$key" > "$PRIV/profiles/$id/profile"
            : > "$PRIV/profiles/$id/logins"
            PROFILE_LABEL[$id]="${scheme:-ldap}://$server $basedn"      # for logs: never the password
        fi
        printf '%s\n' "$login" >> "$PRIV/profiles/$id/logins"
        printf '%s\x1f%s\n' "$login" "$id" >> "$PRIV/$c.map"
    done < "$PRIV/$c.ldap"
done

ad_lookup() {
    local id="$1"
    if ! "$SCRIPTS_DIR/ad_lookup.sh" "$PRIV/profiles/$id/profile" "$PRIV/profiles/$id/logins" \
            > "$PRIV/profiles/$id/results.csv" 2> "$RUN_DIR/ad/$id.log"; then
        touch "$RUN_DIR/ad/$id.failed"
    fi
}
if [ ${#PROFILE_LABEL[@]} -gt 0 ]; then
    run_parallel ad_lookup "${!PROFILE_LABEL[@]}"
fi

declare -A AD_STATUS=() AD_MSG=() AD_COUNT=()
for id in "${!PROFILE_LABEL[@]}"; do
    AD_COUNT[$id]="$(sort -u "$PRIV/profiles/$id/logins" | wc -l)"
    if [ -e "$RUN_DIR/ad/$id.failed" ]; then
        AD_STATUS[$id]="FAILED"; ANY_FAILED=1
        AD_MSG[$id]="$(first_error "$RUN_DIR/ad/$id.log")"
        [ -n "${AD_MSG[$id]}" ] || AD_MSG[$id]="$(tail -1 "$RUN_DIR/ad/$id.log" | cut -c1-300)"
        log "ERROR: AD ${PROFILE_LABEL[$id]}: ${AD_MSG[$id]}"
    else
        AD_STATUS[$id]="OK"; AD_MSG[$id]=""
        log "AD ${PROFILE_LABEL[$id]}: ${AD_COUNT[$id]} logins looked up, $(wc -l < "$PRIV/profiles/$id/results.csv") found"
    fi
done

# ---- 3. Per cluster: load AD rows, extract both feeds ----------------------------------
pass2() {
    local i="$1" code="${SRC_CODE[$1]}" id
    [ -e "$RUN_DIR/$code/failed" ] && return
    : > "$PRIV/$code.ad_users.csv"
    for id in $(cut -d $'\x1f' -f2 "$PRIV/$code.map" | sort -u); do
        awk -F, -v id="$id" '
            NR == FNR { split($0, a, "\x1f"); if (a[2] == id) want["\"" a[1] "\""] = 1; next }
            ($1 in want)' "$PRIV/$code.map" "$PRIV/profiles/$id/results.csv" >> "$PRIV/$code.ad_users.csv"
    done
    pg_src "$i" "${PSQL_VARS[@]}" -v "source_code=$code" > "$RUN_DIR/$code/pass2.log" 2>&1 <<SQL || touch "$RUN_DIR/$code/failed"
\i '$SQL_DIR/00_prepare.sql'
\copy ad_users (login, first_name, last_name, owner, cost_centre) FROM '$PRIV/$code.ad_users.csv' WITH (FORMAT csv)
\i '$SQL_DIR/10_base.sql'
\i '$SQL_DIR/20_checks.sql'
\i '$SQL_DIR/30_access.sql'
\i '$SQL_DIR/31_account.sql'
\copy (SELECT * FROM access_feed ORDER BY "id") TO '$PRIV/$code.access.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM account_feed ORDER BY "id", "access") TO '$PRIV/$code.account.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT rolname FROM role_base WHERE rolcanlogin AND hba_line IS NULL ORDER BY 1) TO '$RUN_DIR/$code/no_hba_line.txt'
SQL
}
if [ "$ANY_FAILED" -eq 0 ]; then
    run_parallel pass2 "${!SRC_CODE[@]}"
fi

declare -A STATUS=() MSG=()
for c in "${SRC_CODE[@]}"; do
    if [ -e "$RUN_DIR/$c/failed" ]; then
        STATUS[$c]="FAILED"; ANY_FAILED=1
        MSG[$c]="$(first_error "$RUN_DIR/$c/pass2.log")"
        [ -n "${MSG[$c]}" ] || MSG[$c]="$(first_error "$RUN_DIR/$c/pass1.log")"
        log "ERROR: $c: ${MSG[$c]}"
    elif [ -s "$PRIV/$c.access.csv" ]; then
        STATUS[$c]="OK"; MSG[$c]=""
        log "$c: $(( $(wc -l < "$PRIV/$c.access.csv") - 1 )) access rows, $(( $(wc -l < "$PRIV/$c.account.csv") - 1 )) account rows"
        if [ -s "$RUN_DIR/$c/no_hba_line.txt" ]; then
            log "NOTE: $c: logins with no pg_hba.conf line (reported as Local DB Account):" \
                "$(paste -sd ',' "$RUN_DIR/$c/no_hba_line.txt" | sed 's/,/, /g')"
        fi
    else
        STATUS[$c]="SKIPPED"; MSG[$c]="not extracted because another step failed"
    fi
done

# ---- 4. Combine and publish -------------------------------------------------------------
publish() {   # publish <part: access|account> <file name>
    local part="$1" name="$2" tmp="$OUTPUT_DIR/.$2.tmp" first=1 c
    : > "$tmp" || return 1
    for c in "${SRC_CODE[@]}"; do
        if [ "$first" -eq 1 ]; then cat "$PRIV/$c.$part.csv" >> "$tmp" || return 1; first=0
        else tail -n +2 "$PRIV/$c.$part.csv" >> "$tmp" || return 1; fi
    done
    mv -f "$tmp" "$OUTPUT_DIR/$name" || return 1
    log "$name published: $(( $(wc -l < "$OUTPUT_DIR/$name") - 1 )) rows"
    gzip -c "$OUTPUT_DIR/$name" > "$STATE_DIR/archive/$RUN_ID/$name.gz"
}

RUN_MSG=""
if [ "$ANY_FAILED" -eq 0 ]; then
    mkdir -p "$STATE_DIR/archive/$RUN_ID"
    if publish access "$ACCESS_FILE_NAME" && publish account "$ACCOUNT_FILE_NAME"; then
        RESULT="OK"; EXIT_CODE=0
    else
        RESULT="FAILED"; EXIT_CODE=2; RUN_MSG="could not write to $OUTPUT_DIR"
        log "ERROR: $RUN_MSG"
    fi
else
    RESULT="FAILED"; EXIT_CODE=2
    RUN_MSG="nothing published; files already in $OUTPUT_DIR left as they were"
    log "$RUN_MSG"
fi

# ---- Status file, email, housekeeping ----------------------------------------------------
json() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$(tr -d '\000-\037' <<< "$s")"; }
{
    printf '{\n  "run_id": %s,\n  "finished_at": %s,\n  "result": %s,\n  "exit_code": %d,\n  "message": %s,\n' \
        "$(json "$RUN_ID")" "$(json "$(date -Iseconds)")" "$(json "$RESULT")" "$EXIT_CODE" "$(json "$RUN_MSG")"
    printf '  "clusters": ['
    sep=$'\n'
    for c in "${SRC_CODE[@]}"; do
        printf '%s    {"code": %s, "status": %s, "message": %s}' \
            "$sep" "$(json "$c")" "$(json "${STATUS[$c]}")" "$(json "${MSG[$c]}")"
        sep=$',\n'
    done
    printf '\n  ],\n  "ad_profiles": ['
    sep=$'\n'
    for id in "${!PROFILE_LABEL[@]}"; do
        printf '%s    {"profile": %s, "status": %s, "logins": %d, "message": %s}' \
            "$sep" "$(json "${PROFILE_LABEL[$id]}")" "$(json "${AD_STATUS[$id]}")" "${AD_COUNT[$id]}" "$(json "${AD_MSG[$id]}")"
        sep=$',\n'
    done
    printf '\n  ]\n}\n'
} > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
cp "$STATUS_FILE" "$RUN_DIR/status.json"

if [ -n "$MAIL_TO" ] && { [ "$MAIL_ON" = "always" ] || [ "$EXIT_CODE" -ne 0 ]; }; then
    if command -v mail >/dev/null 2>&1; then
        {
            echo "SailPoint feed run $RUN_ID: $RESULT"
            [ -n "$RUN_MSG" ] && echo "$RUN_MSG"
            for c in "${SRC_CODE[@]}"; do echo "$c: ${STATUS[$c]}${MSG[$c]:+ - ${MSG[$c]}}"; done
            for id in "${!PROFILE_LABEL[@]}"; do
                echo "AD ${PROFILE_LABEL[$id]}: ${AD_STATUS[$id]}${AD_MSG[$id]:+ - ${AD_MSG[$id]}}"
            done
            echo; echo "Logs: $RUN_DIR"
        } | mail -s "SailPoint feeds $RESULT on $(hostname)" "$MAIL_TO" \
          || log "WARNING: could not send email to $MAIL_TO"
    else
        log "WARNING: MAIL_TO is set but no 'mail' command is installed"
    fi
fi

find "$STATE_DIR/runs" "$STATE_DIR/archive" -mindepth 1 -maxdepth 1 -type d \
     -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null

log "done: $RESULT (exit $EXIT_CODE)"
exit "$EXIT_CODE"
