#!/usr/bin/env bash
# Create or refresh the SailPoint feed views in the database, from sql/views/*.sql.
#
#   sailpoint.v_role_base              shared logic (privilege rule, classification, status)
#   sailpoint.v_access_feed            Access feed, 12 columns
#   sailpoint.v_account_feed_rows      Account feed, one row per account per role  (option 2)
#   sailpoint.v_account_feed_combined  Account feed, one row per account           (option 1)
#
# Safe to rerun at any time: all files run in ONE transaction, in file-name order.
# If any file fails, nothing changes and the previous views stay in place.
# Run it after the one-time DBA setup, and again whenever a file in sql/views changes
# (on every cluster). It does not touch run_feeds.sh or the CSV exports.
#
# Settings come from config/feeds.env (override the path with FEEDS_ENV=/path/to/file).
# The views are owned by the account in PGUSER.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIEWS_DIR="$SCRIPT_DIR/../sql/views"
FEEDS_ENV="${FEEDS_ENV:-$SCRIPT_DIR/../config/feeds.env}"
if [ ! -r "$FEEDS_ENV" ]; then
    echo "apply_views: config file not found: $FEEDS_ENV (copy config/feeds.env.example)" >&2
    exit 2
fi
# shellcheck source=../config/feeds.env.example
. "$FEEDS_ENV"
export PGHOST PGPORT PGDATABASE PGUSER

log() { echo "$(date '+%F %T') apply_views: $*"; }

shopt -s nullglob
FILES=("$VIEWS_DIR"/*.sql)
if [ ${#FILES[@]} -eq 0 ]; then
    echo "apply_views: no .sql files found in $VIEWS_DIR" >&2
    exit 2
fi

# Build one psql input wrapped in BEGIN/COMMIT. Each file is included with \i, so an error
# message names the file. With ON_ERROR_STOP, psql exits at the first error before COMMIT,
# and the server rolls the whole transaction back.
INPUT="SET client_min_messages = warning;"$'\n'"BEGIN;"$'\n'
for f in "${FILES[@]}"; do
    INPUT+="\\echo '  applying $(basename "$f")'"$'\n'
    INPUT+="\\i '$f'"$'\n'
done
INPUT+="COMMIT;"$'\n'

log "applying ${#FILES[@]} files to database '$PGDATABASE' as '$PGUSER'"
psql -X -q -v ON_ERROR_STOP=1 <<< "$INPUT"

# Show what is now in place.
psql -X -At -v ON_ERROR_STOP=1 -c "
    SELECT '  ' || c.relname || ' (' || count(a.attnum) || ' columns)'
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
    WHERE n.nspname = 'sailpoint' AND c.relkind = 'v'
    GROUP BY c.relname ORDER BY c.relname"

log "done"
