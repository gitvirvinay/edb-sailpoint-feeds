# edb-sailpoint-feeds: EPAS → SailPoint feeds

Nightly CSV feeds of database accounts and roles from one or more EDB Postgres Advanced Server
(EPAS) clusters, for SailPoint user and role attestation. A central Linux server reads every
cluster and publishes **one combined file per feed**:

| Feed | File | One row per | Columns |
|---|---|---|---|
| Access | `access_feed.csv` | role that cannot log in (entitlement), per cluster | 12 |
| Account | `account_feed.csv` | login account per role it holds, per cluster | 18 |

A single cluster is simply one line in `config/sources.conf`.
Column details: [docs/field_mapping.md](docs/field_mapping.md). Design and reasoning:
[docs/design.md](docs/design.md).

## How it works

1. For each cluster, the central server reads `pg_hba.conf` (through `pg_hba_file_rules`) and
   classifies every login by the line that applies to it:

   | That line | type | subtype |
   |---|---|---|
   | `ldap`, `ldapbasedn` contains `OU=Non Person Id` | Non-Personal ID | Application Connection |
   | `ldap`, `ldapbasedn` contains `OU=Person ID` | Personal ID | Primary |
   | any other method, or no line | Local DB Account | Local Authentication |

2. It looks each AD login up in **the AD server and branch named on its own `pg_hba.conf`
   line**, with that line's bind account and search rule, to fill names (and owner and cost
   centre for non-person accounts). One lookup per distinct AD profile.
3. It extracts both feeds from each cluster, prefixes IDs with the cluster's code
   (`PRD1:app_read`), combines them and publishes them atomically.

**Nothing is stored in the clusters**: the SQL in `sql/feed/` uses temporary tables and views
that disappear when the session ends, so what runs is always exactly what is in this repo.
**Runs are independent**: if any cluster or AD lookup fails, nothing is published and the files
already in the output folder stay as they are.

## Repository layout

```
config/central.env.example    settings for the central server (copy to central.env; never commit it)
config/sources.conf.example   one line per cluster (copy to sources.conf; never commit it)
sql/setup/01_create_feed_account.sql   one-time DBA setup on each cluster: the feed login account
sql/feed/00_prepare.sql       session checks + temporary table for AD data
sql/feed/10_base.sql          ALL shared rules: pg_hba classification, privileges, status, prefix
sql/feed/15_ldap_logins.sql   AD settings of each AD login's pg_hba.conf line
sql/feed/20_checks.sql        stop on pg_hba.conf problems or IDs over 32 characters
sql/feed/30_access.sql        Access feed (12 columns)
sql/feed/31_account.sql       Account feed (18 columns)
scripts/collect_all.sh        the whole run; call this from cron
scripts/ad_lookup.sh          looks logins up in one AD profile
scripts/lib.sh                shared helpers
docs/design.md                design, decisions and limitations
docs/field_mapping.md         SailPoint column specs and where each value comes from
docs/requirements_prompt.md   the requirements in one message (for AI assistants or new team members)
old/                          earlier versions, kept for reference only (not used)
```

## Cluster setup (DBA, one time per cluster)

### 1. Create the feed account

```bash
psql -h <host> -p 5444 -U enterprisedb -d postgres -f sql/setup/01_create_feed_account.sql
# other name:  psql ... -v feed_user=svc_sailpoint -f sql/setup/01_create_feed_account.sql
```

This creates the login `sailpoint_feed` (password asked interactively) with the rights to read
`pg_hba_file_rules` (including the LDAP bind settings) and `sys.dba_users`. Its last query must
return `sys | dba_users`; if it returns nothing, the EPAS Oracle-compatibility views are missing
in the `postgres` database (`SHOW db_dialect;`) and the feed cannot run there.

### 2. Allow the central server in `pg_hba.conf`

```
# TYPE   DATABASE  USER            ADDRESS                  METHOD
hostssl  postgres  sailpoint_feed  <central-server-ip>/32   scram-sha-256
```

- Put it **above** any LDAP line and any `all` line: `pg_hba.conf` uses the first match.
- `hostssl`: the feed reads the AD bind passwords over this connection.
- Use `md5` instead if the cluster still stores md5 passwords (`SHOW password_encryption;`).
- Reload and verify: `SELECT pg_reload_conf();` then
  `SELECT line_number, address, auth_method, error FROM pg_hba_file_rules WHERE 'sailpoint_feed' = ANY (user_name);`

The feed account is itself a local account, so it appears in the Account feed as
`Local DB Account` with `isPrivilegedFlag` = TRUE (superuser). That is correct: it is a
privileged service account and should be attested like any other.

## Central server setup (one time)

Requirements: `bash`, `psql` 12+, `ldapsearch` (`openldap-clients` / `ldap-utils`), `flock`, `gzip`.

```bash
git clone <repo-url> /opt/edb-sailpoint-feeds
cd /opt/edb-sailpoint-feeds
cp config/central.env.example  config/central.env && chmod 600 config/central.env
cp config/sources.conf.example config/sources.conf
vi config/central.env          # OU names, output folder, email ...
vi config/sources.conf         # one line per cluster

# One ~/.pgpass line per cluster (no AD passwords needed here: they come from pg_hba.conf)
echo 'pgprd01.example.com:5444:postgres:sailpoint_feed:<password>' >> ~/.pgpass
chmod 600 ~/.pgpass

sudo mkdir -p /var/lib/edb-sailpoint-feeds && sudo chown "$USER" /var/lib/edb-sailpoint-feeds
chmod +x scripts/*.sh
scripts/collect_all.sh                         # test run
cat /var/lib/edb-sailpoint-feeds/status.json
```

If the AD servers use certificates from an internal CA, set `LDAPTLS_CACERT` in `central.env`.

Schedule it (daily at 01:30):

```
30 1 * * * /opt/edb-sailpoint-feeds/scripts/collect_all.sh >> /var/log/sailpoint_feeds.log 2>&1
```

## Source codes

Each cluster's code in `sources.conf` becomes its ID prefix (`PRD1:app_read`).

- 3-5 characters, A-Z and 0-9; **use 4 or fewer**. Built-in `pg_*` roles are in the feed, and
  the longest on Postgres 16 (`pg_use_reserved_connections`, 27 characters) only fits the
  32-character `id` limit with a code of up to 4 characters.
- **Never change a code once live**: SailPoint would see that cluster's accounts as removed and re-added.

## When a run fails

Exit code 0 = both files published; 2 = nothing published (previous files untouched).
`status.json` lists each cluster and AD profile as `OK`, `FAILED` or `SKIPPED` with a message;
`runs/<run id>/` under the state folder holds the logs. Common messages:

| Message | Fix |
|---|---|
| `pg_hba.conf line N has neither OU=Person ID nor OU=Non Person Id` | correct that line's `ldapbasedn`, or the OU names in `central.env` |
| `pg_hba.conf lines N, M point to different OUs` | the same login is on LDAP lines with both OUs: make them consistent |
| `uses simple bind (no ldapbasedn), not supported` | convert the line to search + bind (`ldapbasedn`, `ldapbinddn`) |
| `IDs longer than 32 characters` | shorten the cluster code (or the role name) |
| `Invalid credentials (49)` from an AD profile | the `ldapbindpasswd` on those `pg_hba.conf` lines is wrong or expired |
| `view sys.dba_users not found` | the database has no EPAS Oracle-compatibility views |

## Open items

- [ ] SailPoint: confirm the `CODE:name` ID format and the rows layout of the Account file.
- [ ] Type/subtype spelling against the customer's ID types definition document.
- [ ] AD failure handling: today any AD failure stops the run (to revisit).
- [ ] Optional: test the least-privilege feed account (commented in the setup script).

## Making changes

Work on a branch, open a pull request, and have a DBA review SQL changes before merging to
`main`. Tag each production release (`v2.0`, `v2.1`, ...) so you can tell which version produced
a feed. Update the server with `git pull` (or `git checkout <tag>`); there is nothing to deploy
to the clusters.
