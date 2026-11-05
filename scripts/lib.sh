#!/usr/bin/env bash
# Shared helpers for scripts/collect_all.sh and scripts/ad_lookup.sh. Sourced, not run.
# Loads config/central.env and provides:
#   log, die, load_sources, pg_src, ldap_escape
#   SRC_CODE[], SRC_HOST[], SRC_PORT[], SRC_DB[], SRC_USER[]   one entry per cluster

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPTS_DIR/.." && pwd)"
export REPO_DIR

log() { echo "$(date '+%F %T') ${LOG_NAME:-feeds}: $*"; }
die() { echo "$(date '+%F %T') ${LOG_NAME:-feeds}: ERROR: $*" >&2; exit "${2:-2}"; }

# ---- Settings -----------------------------------------------------------------
CENTRAL_ENV="${CENTRAL_ENV:-$REPO_DIR/config/central.env}"
[ -r "$CENTRAL_ENV" ] || die "config file not found: $CENTRAL_ENV (copy config/central.env.example)"
# shellcheck source=../config/central.env.example
. "$CENTRAL_ENV"

: "${SOURCES_FILE:=$REPO_DIR/config/sources.conf}"
: "${PGUSER:=sailpoint_feed}"
: "${PGDATABASE:=sailpoint}"
: "${PGSSLMODE:=require}"
: "${PGCONNECT_TIMEOUT:=15}"
: "${STATEMENT_TIMEOUT_MS:=600000}"
: "${PARALLEL:=4}"
: "${PERSON_OU:=Person ID}"
: "${NONPERSON_OU:=Non Person Id}"
: "${AD_BATCH:=200}"
: "${ACCESS_FILE_NAME:=access_feed.csv}"
: "${ACCOUNT_FILE_NAME:=account_feed.csv}"
: "${STATE_DIR:=/var/lib/edb-sailpoint-feeds}"
: "${KEEP_DAYS:=90}"
: "${STATUS_FILE:=$STATE_DIR/status.json}"
: "${MAIL_TO:=}"
: "${MAIL_ON:=problems}"
export PGSSLMODE PGCONNECT_TIMEOUT
export PGOPTIONS="-c statement_timeout=$STATEMENT_TIMEOUT_MS"

# ---- Clusters (sources.conf) ----------------------------------------------------
SRC_CODE=(); SRC_HOST=(); SRC_PORT=(); SRC_DB=(); SRC_USER=()
load_sources() {
    [ -r "$SOURCES_FILE" ] || die "sources file not found: $SOURCES_FILE (copy config/sources.conf.example)"
    local line_no=0 code host port db user extra
    declare -A seen=()
    while read -r code host port db user extra || [ -n "${code:-}" ]; do
        line_no=$((line_no + 1))
        [[ -z "${code:-}" || "$code" == \#* ]] && continue
        [ -z "${extra:-}" ] || die "$SOURCES_FILE line $line_no: too many fields"
        [[ "$code" =~ ^[A-Z0-9]{3,5}$ ]] \
            || die "$SOURCES_FILE line $line_no: code '$code' must be 3-5 characters A-Z/0-9"
        [ -z "${seen[$code]:-}" ] || die "$SOURCES_FILE line $line_no: code '$code' is used twice"
        [[ -n "${host:-}" && "${port:-}" =~ ^[0-9]+$ ]] \
            || die "$SOURCES_FILE line $line_no: expected CODE HOST PORT [DATABASE] [USER]"
        seen[$code]=1
        SRC_CODE+=("$code"); SRC_HOST+=("$host"); SRC_PORT+=("$port")
        SRC_DB+=("${db:-$PGDATABASE}"); SRC_USER+=("${user:-$PGUSER}")
    done < "$SOURCES_FILE"
    [ ${#SRC_CODE[@]} -gt 0 ] || die "no clusters listed in $SOURCES_FILE"
}

# Run psql against cluster number $1 (index into SRC_*), passing the remaining arguments.
pg_src() {
    local i="$1"; shift
    PGHOST="${SRC_HOST[$i]}" PGPORT="${SRC_PORT[$i]}" PGDATABASE="${SRC_DB[$i]}" \
    PGUSER="${SRC_USER[$i]}" psql -X -q -v ON_ERROR_STOP=1 "$@"
}

# Escape characters that have special meaning in LDAP filters (RFC 4515).
ldap_escape() { sed -e 's/\\/\\5c/g' -e 's/\*/\\2a/g' -e 's/(/\\28/g' -e 's/)/\\29/g'; }
