#!/usr/bin/env bash
# Produce both SailPoint CSV feeds, in order:
#   1. ad_npid_sync.sh   refresh the list of AD non-person IDs
#   2. access_feed.sql   -> $OUTPUT_DIR/access_feed.csv
#   3. account feed      -> $OUTPUT_DIR/account_feed.csv  (layout set by ACCOUNT_FEED_SQL)
#
# Each CSV is written to a temporary file first and renamed only when complete,
# so SailPoint never picks up a half-written file. If any step fails, the script
# stops with a non-zero exit code and the previous CSVs are left in place.
#
# Example cron entry (daily at 02:00):
#   0 2 * * * /opt/epas-sailpoint-feeds/scripts/run_feeds.sh >> /var/log/sailpoint_feeds.log 2>&1
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$SCRIPT_DIR/../sql"
FEEDS_ENV="${FEEDS_ENV:-$SCRIPT_DIR/../config/feeds.env}"
export FEEDS_ENV
if [ ! -r "$FEEDS_ENV" ]; then
    echo "run_feeds: config file not found: $FEEDS_ENV (copy config/feeds.env.example)" >&2
    exit 2
fi
# shellcheck source=../config/feeds.env.example
. "$FEEDS_ENV"
export PGHOST PGPORT PGDATABASE PGUSER

log() { echo "$(date '+%F %T') run_feeds: $*"; }

# Run a SQL file and publish its CSV output atomically.
export_csv() {
    local sql_file="$1" csv_name="$2"
    local tmp="$OUTPUT_DIR/.$csv_name.tmp"
    psql -X -v ON_ERROR_STOP=1 --csv -f "$SQL_DIR/$sql_file" -o "$tmp"
    mv -f "$tmp" "$OUTPUT_DIR/$csv_name"
    log "$csv_name written ($(( $(wc -l < "$OUTPUT_DIR/$csv_name") - 1 )) rows) from $sql_file"
}

mkdir -p "$OUTPUT_DIR"
log "start"

# Fail early, with a clear message, if the EPAS Oracle-compatibility view is missing
# (otherwise both feeds would stop with a cryptic "relation does not exist" error).
if [ -z "$(psql -X -At -v ON_ERROR_STOP=1 -c "SELECT to_regclass('sys.dba_users')")" ]; then
    echo "run_feeds: view sys.dba_users not found in database '$PGDATABASE'" \
         "(EPAS Oracle-compatibility views missing; see README)" >&2
    exit 3
fi

"$SCRIPT_DIR/ad_npid_sync.sh"
export_csv "access_feed.sql"   "access_feed.csv"
export_csv "$ACCOUNT_FEED_SQL" "account_feed.csv"

log "done"
