#!/usr/bin/env bash
# For each login account in the database, ask AD whether it is a non-person
# (service) account, and store the matches in table sailpoint.ad_npids.
# The account feed reads that table to set type/subtype. Run it before the account feed
# (run_feeds.sh does this automatically).
#
# Needs: ldapsearch (openldap-clients / ldap-utils), psql, a read-only AD bind account.
#   RHEL/Rocky:  sudo dnf install openldap-clients
#   Ubuntu:      sudo apt install ldap-utils
#
# Settings come from config/feeds.env (override the path with FEEDS_ENV=/path/to/file).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEEDS_ENV="${FEEDS_ENV:-$SCRIPT_DIR/../config/feeds.env}"
if [ ! -r "$FEEDS_ENV" ]; then
    echo "ad_npid_sync: config file not found: $FEEDS_ENV (copy config/feeds.env.example)" >&2
    exit 2
fi
# shellcheck source=../config/feeds.env.example
. "$FEEDS_ENV"
export PGHOST PGPORT PGDATABASE PGUSER
BATCH="${BATCH:-200}"

log() { echo "$(date '+%F %T') ad_npid_sync: $*"; }

OUT="$(mktemp)"
LOGINS="$(mktemp)"
trap 'rm -f "$OUT" "$LOGINS"' EXIT

# 1. Get the database's login accounts. Only these are looked up in AD.
psql -X -At -v ON_ERROR_STOP=1 \
     -c "SELECT lower(rolname) FROM pg_roles WHERE rolcanlogin ORDER BY 1" > "$LOGINS"

# Escape characters that have special meaning in LDAP filters (RFC 4515)
ldap_escape() { sed -e 's/\\/\\5c/g' -e 's/\*/\\2a/g' -e 's/(/\\28/g' -e 's/)/\\29/g'; }

# 2. Ask AD, in batches, which of those logins match the non-person criteria.
#    Logins with no AD account (local DB users) simply return nothing.
#    If AD is unreachable or the bind fails, the script stops here (set -e / pipefail)
#    and the table keeps its previous contents.
: > "$OUT"
mapfile -t NAMES < <(ldap_escape < "$LOGINS")
for ((i = 0; i < ${#NAMES[@]}; i += BATCH)); do
    NAME_FILTER=""
    for n in "${NAMES[@]:i:BATCH}"; do NAME_FILTER+="(sAMAccountName=$n)"; done

    ldapsearch -LLL -o ldif-wrap=no -E pr=1000/noprompt \
        -H "$LDAP_URI" -D "$BIND_DN" -y "$BIND_PW_FILE" \
        -b "$SEARCH_BASE" "(&$FILTER(|$NAME_FILTER))" sAMAccountName \
      | awk -F': ' '/^sAMAccountName: /{print tolower($2)}' >> "$OUT"
done
sort -u -o "$OUT" "$OUT"

log "checked $(wc -l < "$LOGINS") DB logins, $(wc -l < "$OUT") are AD non-person IDs"

# 3. Replace the table contents in one transaction.
psql -X -v ON_ERROR_STOP=1 -q <<SQL
CREATE SCHEMA IF NOT EXISTS sailpoint;
CREATE TABLE IF NOT EXISTS sailpoint.ad_npids (
    rolname   text PRIMARY KEY,
    synced_at timestamptz NOT NULL DEFAULT now()
);
BEGIN;
TRUNCATE sailpoint.ad_npids;
\copy sailpoint.ad_npids (rolname) FROM '$OUT'
COMMIT;
SQL

log "table sailpoint.ad_npids refreshed"
