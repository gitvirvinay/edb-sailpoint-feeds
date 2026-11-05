#!/usr/bin/env bash
# Shared helpers for the multi-source scripts in scripts/central/. Sourced, not run.
# Loads config/central.env and config/sources.conf, and provides:
#   log, die, ldap_escape, pg_src <index> <psql args...>
#   SRC_CODE[], SRC_HOST[], SRC_PORT[], SRC_DB[], SRC_USER[]  (one entry per cluster)

CENTRAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$CENTRAL_DIR/../.." && pwd)"
export REPO_DIR

log() { echo "$(date '+%F %T') ${LOG_NAME:-central}: $*"; }
die() { echo "$(date '+%F %T') ${LOG_NAME:-central}: ERROR: $*" >&2; exit "${2:-2}"; }

# ---- Settings ---------------------------------------------------------------
CENTRAL_ENV="${CENTRAL_ENV:-$REPO_DIR/config/central.env}"
[ -r "$CENTRAL_ENV" ] || die "config file not found: $CENTRAL_ENV (copy config/central.env.example)"
# shellcheck source=../../config/central.env.example
. "$CENTRAL_ENV"

: "${SOURCES_FILE:=$REPO_DIR/config/sources.conf}"
: "${PGUSER:=sailpoint_feed}"
: "${PGSSLMODE:=require}"
: "${PGCONNECT_TIMEOUT:=15}"
: "${STATEMENT_TIMEOUT_MS:=600000}"
: "${PARALLEL:=4}"
: "${AD_BATCH:=200}"
: "${ACCESS_FILE_NAME:=access_feed.csv}"
: "${ACCOUNT_FILE_NAME:=account_feed.csv}"
: "${ACCOUNT_LAYOUT:=rows}"
: "${MAX_STALE_HOURS:=48}"
: "${KEEP_DAYS:=90}"
: "${STATE_DIR:=/var/lib/edb-sailpoint-feeds}"
: "${STATUS_FILE:=$STATE_DIR/status.json}"
: "${MAIL_TO:=}"
: "${MAIL_ON:=problems}"
export PGSSLMODE PGCONNECT_TIMEOUT
export PGOPTIONS="-c statement_timeout=$STATEMENT_TIMEOUT_MS"

# ---- Clusters (sources.conf) --------------------------------------------------
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
        [[ -n "${host:-}" && "${port:-}" =~ ^[0-9]+$ && -n "${db:-}" ]] \
            || die "$SOURCES_FILE line $line_no: expected CODE HOST PORT DATABASE [USER]"
        seen[$code]=1
        SRC_CODE+=("$code"); SRC_HOST+=("$host"); SRC_PORT+=("$port"); SRC_DB+=("$db")
        SRC_USER+=("${user:-$PGUSER}")
    done < "$SOURCES_FILE"
    [ ${#SRC_CODE[@]} -gt 0 ] || die "no clusters listed in $SOURCES_FILE"
}

# Run psql against cluster number $1 (index into SRC_*), passing the remaining arguments.
pg_src() {
    local i="$1"; shift
    PGHOST="${SRC_HOST[$i]}" PGPORT="${SRC_PORT[$i]}" PGDATABASE="${SRC_DB[$i]}" \
    PGUSER="${SRC_USER[$i]}" psql -X -v ON_ERROR_STOP=1 "$@"
}

# Escape characters that have special meaning in LDAP filters (RFC 4515).
ldap_escape() { sed -e 's/\\/\\5c/g' -e 's/\*/\\2a/g' -e 's/(/\\28/g' -e 's/)/\\29/g'; }

# Age of a file in whole hours (large number if missing).
age_hours() {
    [ -e "$1" ] || { echo 999999; return; }
    echo $(( ( $(date +%s) - $(stat -c %Y "$1") ) / 3600 ))
}
