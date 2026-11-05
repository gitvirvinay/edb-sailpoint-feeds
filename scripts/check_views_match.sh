#!/usr/bin/env bash
# Regression check: do the views in sql/views still produce exactly the same rows as the
# single-database feed files in sql/ (access_feed.sql, account_feed_option*.sql)?
#
#   FEEDS_ENV=config/feeds.env scripts/check_views_match.sh
#
# Run it after changing anything in sql/ or sql/views (and scripts/apply_views.sh) on a
# test cluster. It compares the outputs byte for byte, with the multi-source data
# (sailpoint.ad_users, sailpoint.feed_settings) emptied INSIDE a transaction that is
# rolled back, so nothing in the database changes. Avoid running it during the nightly run.
#
# Exit code: 0 = all three match, 1 = a difference was found, 2 = could not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$SCRIPT_DIR/../sql"
FEEDS_ENV="${FEEDS_ENV:-$SCRIPT_DIR/../config/feeds.env}"
[ -r "$FEEDS_ENV" ] || { echo "check_views_match: config file not found: $FEEDS_ENV" >&2; exit 2; }
# shellcheck source=../config/feeds.env.example
. "$FEEDS_ENV"
export PGHOST PGPORT PGDATABASE PGUSER

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

psql -X -q -v ON_ERROR_STOP=1 --csv > /dev/null <<SQL || exit 2
BEGIN;
DELETE FROM sailpoint.ad_users;
DELETE FROM sailpoint.feed_settings;
\o $WORK/file_access.csv
\i $SQL_DIR/access_feed.sql
\o $WORK/view_access.csv
SELECT * FROM sailpoint.v_access_feed ORDER BY "id";
\o $WORK/file_rows.csv
\i $SQL_DIR/account_feed_option2_rows.sql
\o $WORK/view_rows.csv
SELECT * FROM sailpoint.v_account_feed_rows ORDER BY "id", "access";
\o $WORK/file_combined.csv
\i $SQL_DIR/account_feed_option1_combined.sql
\o $WORK/view_combined.csv
SELECT * FROM sailpoint.v_account_feed_combined ORDER BY "id";
\o
ROLLBACK;
SQL

RESULT=0
for part in access rows combined; do
    if cmp -s "$WORK/file_$part.csv" "$WORK/view_$part.csv"; then
        echo "MATCH     $part ($(( $(wc -l < "$WORK/file_$part.csv") - 1 )) rows)"
    else
        echo "DIFFERENT $part"; diff "$WORK/file_$part.csv" "$WORK/view_$part.csv" | head -20
        RESULT=1
    fi
done
exit "$RESULT"
