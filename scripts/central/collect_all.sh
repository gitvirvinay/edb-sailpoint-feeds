#!/usr/bin/env bash
# MULTI-SOURCE mode: build one combined Access file and one combined Account file from
# every EPAS cluster in config/sources.conf. Runs on the central server, from cron:
#
#   30 1 * * * /opt/edb-sailpoint-feeds/scripts/central/collect_all.sh >> /var/log/sailpoint_central.log 2>&1
#
# Steps
#   1. Read the login names of every cluster.
#   2. Look them all up in AD once (ad_lookup.sh).
#   3. Per cluster, in one transaction: load its AD rows into sailpoint.ad_users, set its
#      source code, check ID lengths, and extract both feeds from the sailpoint views.
#   4. Combine the per-cluster files (header once) and publish them atomically.
#
# Tolerant failure rule: a cluster (or AD) that cannot be read reuses its last good extract
# for up to MAX_STALE_HOURS. Beyond that the run fails and the published files are not touched.
#
# Exit codes: 0 = all fresh, 1 = published with reused data, 2 = failed, nothing published.
# Every run also writes STATUS_FILE (JSON) and, if MAIL_TO is set, can send an email.
set -uo pipefail
LOG_NAME="collect_all"
# shellcheck source=lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
load_sources

case "$ACCOUNT_LAYOUT" in
    rows)     ACCOUNT_VIEW="sailpoint.v_account_feed_rows";     ACCOUNT_ORDER='"id", "access"' ;;
    combined) ACCOUNT_VIEW="sailpoint.v_account_feed_combined"; ACCOUNT_ORDER='"id"' ;;
    *)        die "ACCOUNT_LAYOUT must be 'rows' or 'combined' (is '$ACCOUNT_LAYOUT')" ;;
esac
[ -n "${OUTPUT_DIR:-}" ] || die "OUTPUT_DIR is not set in $CENTRAL_ENV"
mkdir -p "$STATE_DIR/runs" "$STATE_DIR/last_good" "$STATE_DIR/archive" "$OUTPUT_DIR" \
    || die "cannot create $STATE_DIR or $OUTPUT_DIR"

# Only one run at a time.
exec 9> "$STATE_DIR/collect_all.lock"
flock -n 9 || die "another run is still active"

RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"
LAST_GOOD="$STATE_DIR/last_good"
mkdir -p "$RUN_DIR"
log "start run $RUN_ID: ${#SRC_CODE[@]} clusters, account layout '$ACCOUNT_LAYOUT'"

# Run function $1 for every cluster index, at most PARALLEL at a time.
run_parallel() {
    local fn="$1" i
    for i in "${!SRC_CODE[@]}"; do
        "$fn" "$i" &
        while [ "$(jobs -rp | wc -l)" -ge "$PARALLEL" ]; do wait -n; done
    done
    wait
}

# First error line of a log, for messages.
first_error() { grep -m1 -E 'ERROR|FATAL|error|could not' "$1" 2>/dev/null | sed -E 's/^psql:[^ ]* //' | cut -c1-200; }

# ---- 1. Logins from every cluster --------------------------------------------------
get_logins() {
    local i="$1" d="$RUN_DIR/${SRC_CODE[$1]}"
    mkdir -p "$d"
    if ! pg_src "$i" -At -c "SELECT lower(rolname) FROM pg_roles WHERE rolcanlogin ORDER BY 1" \
            > "$d/logins.txt" 2> "$d/error.log"; then
        touch "$d/unreachable"
    fi
}
run_parallel get_logins

# ---- 2. One AD lookup for all logins ---------------------------------------------------
AD_STATUS="FRESH"; AD_AGE=0; AD_MSG=""
cat_reachable_logins() {
    local c
    for c in "${SRC_CODE[@]}"; do
        [ -e "$RUN_DIR/$c/unreachable" ] || cat "$RUN_DIR/$c/logins.txt"
    done
}
cat_reachable_logins | sort -u > "$RUN_DIR/all_logins.txt"

if [ ! -s "$RUN_DIR/all_logins.txt" ]; then
    AD_STATUS="SKIPPED"; AD_MSG="no cluster could be read"
    : > "$RUN_DIR/ad_users.csv"
elif "$CENTRAL_DIR/ad_lookup.sh" "$RUN_DIR/all_logins.txt" \
        > "$RUN_DIR/ad_users.csv" 2> "$RUN_DIR/ad_lookup.log"; then
    cp "$RUN_DIR/ad_users.csv" "$LAST_GOOD/.ad_users.csv.tmp" && mv -f "$LAST_GOOD/.ad_users.csv.tmp" "$LAST_GOOD/ad_users.csv"
    log "AD lookup: $(wc -l < "$RUN_DIR/ad_users.csv") logins found"
else
    AD_MSG="$(first_error "$RUN_DIR/ad_lookup.log")"; [ -n "$AD_MSG" ] || AD_MSG="$(tail -1 "$RUN_DIR/ad_lookup.log")"
    AD_AGE="$(age_hours "$LAST_GOOD/ad_users.csv")"
    if [ "$AD_AGE" -le "$MAX_STALE_HOURS" ]; then
        AD_STATUS="REUSED"
        cp "$LAST_GOOD/ad_users.csv" "$RUN_DIR/ad_users.csv"
        log "WARNING: AD lookup failed ($AD_MSG); reusing AD data from ${AD_AGE}h ago"
    else
        AD_STATUS="FAILED"
        log "ERROR: AD lookup failed ($AD_MSG) and no AD data newer than ${MAX_STALE_HOURS}h"
    fi
fi

# ---- 3. Per cluster: load AD rows, set source code, extract -------------------------
extract() {
    local i="$1" code="${SRC_CODE[$1]}" d="$RUN_DIR/${SRC_CODE[$1]}" combined_check=""
    [ -e "$d/unreachable" ] && return
    [ "$AD_STATUS" = "FAILED" ] && { echo "not extracted: AD data unavailable" > "$d/error.log"; return; }

    # Only this cluster's logins are loaded into its database.
    awk -F, 'NR==FNR { want["\"" $0 "\""] = 1; next } ($1 in want)' \
        "$d/logins.txt" "$RUN_DIR/ad_users.csv" > "$d/ad_users.csv"

    if [ "$ACCOUNT_LAYOUT" = "combined" ]; then
        combined_check="
DO \$\$ DECLARE bad text; BEGIN
    SELECT string_agg(\"id\", ', ') INTO bad FROM (
        SELECT \"id\" FROM sailpoint.v_account_feed_combined
        WHERE length(\"access\") > 450 ORDER BY 1 LIMIT 5) z;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'access list longer than 450 characters for: %', bad;
    END IF;
END \$\$;"
    fi

    cat > "$d/extract.sql" <<SQL
BEGIN;
DO \$\$ BEGIN
    IF to_regclass('sys.dba_users') IS NULL THEN
        RAISE EXCEPTION 'view sys.dba_users not found (EPAS Oracle-compatibility views missing)';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'sailpoint' AND table_name = 'v_role_base'
                     AND column_name = 'id_prefix') THEN
        RAISE EXCEPTION 'sailpoint views missing or out of date: run scripts/central/apply_views_all.sh';
    END IF;
END \$\$;
DELETE FROM sailpoint.ad_users;
\copy sailpoint.ad_users (rolname, is_npid, first_name, last_name, owner, cost_centre) FROM '$d/ad_users.csv' WITH (FORMAT csv)
INSERT INTO sailpoint.feed_settings (setting, value) VALUES ('source_code', '$code')
    ON CONFLICT (setting) DO UPDATE SET value = EXCLUDED.value;
DO \$\$ DECLARE bad text; BEGIN
    SELECT string_agg(x, ', ') INTO bad FROM (
        SELECT DISTINCT x FROM (
            SELECT "id" AS x FROM sailpoint.v_access_feed
            UNION ALL
            SELECT "id" FROM sailpoint.v_account_feed_rows) y
        WHERE length(x) > 32 ORDER BY x LIMIT 5) z;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'IDs longer than 32 characters: % (shorten the source code or the role name)', bad;
    END IF;
END \$\$;
$combined_check
\copy (SELECT * FROM sailpoint.v_access_feed ORDER BY "id") TO '$d/access.csv' WITH (FORMAT csv, HEADER)
\copy (SELECT * FROM $ACCOUNT_VIEW ORDER BY $ACCOUNT_ORDER) TO '$d/account.csv' WITH (FORMAT csv, HEADER)
COMMIT;
SQL

    if pg_src "$i" -q -f "$d/extract.sql" > "$d/extract.log" 2>&1; then
        local tmp="$LAST_GOOD/.$code.tmp"
        rm -rf "$tmp" && mkdir -p "$tmp" \
          && cp "$d/access.csv" "$d/account.csv" "$tmp/" \
          && echo "$ACCOUNT_LAYOUT" > "$tmp/layout" && touch "$tmp/extracted_at" \
          && rm -rf "${LAST_GOOD:?}/$code" && mv "$tmp" "$LAST_GOOD/$code" \
          && touch "$d/fresh"
    else
        cp "$d/extract.log" "$d/error.log"
    fi
}
run_parallel extract

# ---- Decide each cluster: FRESH / REUSED / FAILED ---------------------------------------
declare -A STATUS=() AGE=() MSG=()
ANY_FAILED=0; ANY_REUSED=0
[ "$AD_STATUS" = "REUSED" ] && ANY_REUSED=1
[ "$AD_STATUS" = "FAILED" ] && ANY_FAILED=1
for c in "${SRC_CODE[@]}"; do
    if [ -e "$RUN_DIR/$c/fresh" ]; then
        STATUS[$c]="FRESH"; AGE[$c]=0; MSG[$c]=""
        log "$c: fresh ($(( $(wc -l < "$LAST_GOOD/$c/access.csv") - 1 )) access rows," \
            "$(( $(wc -l < "$LAST_GOOD/$c/account.csv") - 1 )) account rows)"
        continue
    fi
    MSG[$c]="$(first_error "$RUN_DIR/$c/error.log")"
    [ -n "${MSG[$c]}" ] || MSG[$c]="$(head -1 "$RUN_DIR/$c/error.log" 2>/dev/null | cut -c1-200)"
    AGE[$c]="$(age_hours "$LAST_GOOD/$c/extracted_at")"
    # Never reuse an extract made with another account layout (same columns, different rows).
    if [ -s "$LAST_GOOD/$c/access.csv" ] \
       && [ "$(cat "$LAST_GOOD/$c/layout" 2>/dev/null)" != "$ACCOUNT_LAYOUT" ]; then
        STATUS[$c]="FAILED"; ANY_FAILED=1
        MSG[$c]="${MSG[$c]}; last good extract uses another account layout, cannot reuse"
        log "ERROR: $c: ${MSG[$c]}"
    elif [ -s "$LAST_GOOD/$c/access.csv" ] && [ "${AGE[$c]}" -le "$MAX_STALE_HOURS" ]; then
        STATUS[$c]="REUSED"; ANY_REUSED=1
        log "WARNING: $c: ${MSG[$c]}; reusing extract from ${AGE[$c]}h ago"
    else
        STATUS[$c]="FAILED"; ANY_FAILED=1
        log "ERROR: $c: ${MSG[$c]}; no extract newer than ${MAX_STALE_HOURS}h"
    fi
done

# All clusters must produce the same columns (same views version).
HEADER_MSG=""
if [ "$ANY_FAILED" -eq 0 ]; then
    for f in access account; do
        n="$(for c in "${SRC_CODE[@]}"; do head -1 "$LAST_GOOD/$c/$f.csv"; done | sort -u | wc -l)"
        if [ "$n" -ne 1 ]; then
            HEADER_MSG="clusters return different $f columns: run scripts/central/apply_views_all.sh"
            log "ERROR: $HEADER_MSG"; ANY_FAILED=1
        fi
    done
fi

# ---- 4. Combine and publish ----------------------------------------------------------
publish() {   # publish <part: access|account> <file name>
    local part="$1" name="$2" tmp="$OUTPUT_DIR/.$2.tmp" first=1 c
    : > "$tmp" || return 1
    for c in "${SRC_CODE[@]}"; do
        if [ "$first" -eq 1 ]; then cat "$LAST_GOOD/$c/$part.csv" >> "$tmp"; first=0
        else tail -n +2 "$LAST_GOOD/$c/$part.csv" >> "$tmp"; fi || return 1
    done
    mv -f "$tmp" "$OUTPUT_DIR/$name" || return 1
    log "$name written: $(( $(wc -l < "$OUTPUT_DIR/$name") - 1 )) rows"
    gzip -c "$OUTPUT_DIR/$name" > "$STATE_DIR/archive/$RUN_ID/$name.gz"
}

if [ "$ANY_FAILED" -eq 0 ]; then
    mkdir -p "$STATE_DIR/archive/$RUN_ID"
    if publish access "$ACCESS_FILE_NAME" && publish account "$ACCOUNT_FILE_NAME"; then
        RESULT="OK"; EXIT_CODE=0
        [ "$ANY_REUSED" -eq 1 ] && { RESULT="WARNING"; EXIT_CODE=1; }
    else
        RESULT="FAILED"; EXIT_CODE=2; HEADER_MSG="could not write to $OUTPUT_DIR"
        log "ERROR: $HEADER_MSG"
    fi
else
    RESULT="FAILED"; EXIT_CODE=2
    log "nothing published; the previous files in $OUTPUT_DIR are unchanged"
fi

# ---- Status file, email, housekeeping ------------------------------------------------
json() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$(tr -d '\000-\037' <<< "$s")"; }
{
    printf '{\n  "run_id": %s,\n  "finished_at": %s,\n  "result": %s,\n  "exit_code": %d,\n' \
        "$(json "$RUN_ID")" "$(json "$(date -Iseconds)")" "$(json "$RESULT")" "$EXIT_CODE"
    printf '  "message": %s,\n' "$(json "$HEADER_MSG")"
    printf '  "ad": {"status": %s, "age_hours": %d, "message": %s},\n' \
        "$(json "$AD_STATUS")" "$AD_AGE" "$(json "$AD_MSG")"
    printf '  "sources": [\n'
    sep=""
    for c in "${SRC_CODE[@]}"; do
        printf '%s    {"code": %s, "status": %s, "age_hours": %d, "message": %s}' \
            "$sep" "$(json "$c")" "$(json "${STATUS[$c]}")" "${AGE[$c]}" "$(json "${MSG[$c]}")"
        sep=$',\n'
    done
    printf '\n  ]\n}\n'
} > "$STATUS_FILE.tmp" && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
cp "$STATUS_FILE" "$RUN_DIR/status.json"

if [ -n "$MAIL_TO" ] && { [ "$MAIL_ON" = "always" ] || [ "$EXIT_CODE" -ne 0 ]; }; then
    if command -v mail >/dev/null 2>&1; then
        {
            echo "SailPoint feed run $RUN_ID: $RESULT (exit $EXIT_CODE)"
            [ -n "$HEADER_MSG" ] && echo "$HEADER_MSG"
            echo "AD: $AD_STATUS ${AD_MSG:+- $AD_MSG}"
            for c in "${SRC_CODE[@]}"; do
                echo "$c: ${STATUS[$c]}${MSG[$c]:+ - ${MSG[$c]}}"
            done
            echo; echo "Details: $RUN_DIR"
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
