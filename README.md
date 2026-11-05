# edb-sailpoint-feeds: EPAS → SailPoint feeds

Nightly CSV feeds from EDB Postgres Advanced Server (EPAS) for SailPoint user and role attestation:

| Feed | File | One row per | Columns |
|---|---|---|---|
| Access | `access_feed.csv` | Role that cannot log in (entitlement) | 12 |
| Account | `account_feed.csv` | Login account (or account × role, see below) | 18 |

## Pick a mode

| Mode | Use when | Runs on | Guide |
|---|---|---|---|
| **Single database** | one EPAS cluster | that cluster's server | [docs/single_database.md](docs/single_database.md) |
| **Multi-source** | several clusters, one combined Access file and one combined Account file | a central server | [docs/multi_source.md](docs/multi_source.md) |

Both modes share the SQL, the database setup below and the classification rules. In
multi-source mode, IDs are prefixed with a source code (`PRD1:app_read`) and names, owner and
cost centre are filled from AD. Single-database mode is unchanged by the multi-source files.

## Repository layout

```
config/feeds.env.example   single mode settings (copy to feeds.env; never commit it)
config/central.env.example multi-source settings (copy to central.env; never commit it)
config/sources.conf.example multi-source list of clusters (copy to sources.conf)
sql/access_feed.sql        Access feed query
sql/account_feed_option1_combined.sql   Account feed: one row per account, roles joined by '|'
sql/account_feed_option2_rows.sql       Account feed: one row per account per role
sql/setup/01_create_sailpoint_db.sql    one-time DBA setup: feed account, database, schema
sql/views/                 the same feeds as database views (used by multi-source mode)
scripts/run_feeds.sh       single mode: runs everything in order; call this from cron
scripts/ad_npid_sync.sh    single mode: stores the database's AD non-person IDs in sailpoint.ad_npids
scripts/apply_views.sh     creates or refreshes the views in sql/views/ on one cluster
scripts/check_views_match.sh  regression check: views = single-mode SQL files, byte for byte
scripts/central/collect_all.sh     multi-source: the whole run; call this from cron
scripts/central/ad_lookup.sh       multi-source: one AD lookup for all clusters
scripts/central/apply_views_all.sh multi-source: apply the views on every cluster
scripts/central/lib.sh             multi-source: shared helpers
docs/single_database.md    single mode: server setup, cron, exit codes
docs/multi_source.md       multi-source: design, source codes, failure rule, setup
docs/field_mapping.md      SailPoint column specs and where each value comes from
docs/requirements_prompt.md  the project requirements in one message (for AI assistants or new team members)
.github/workflows/         optional ShellCheck check on pull requests
.gitattributes             keeps Linux line endings for the scripts
```

## How accounts are classified (both modes)

The Access feed lists the roles that cannot log in (entitlements). The Account feed lists
login accounts, their status, privileges and roles, and classifies each one. Whether an AD
login is a non-person account comes from an AD lookup (OU or attribute, set in the config):

| Account | type | subtype |
|---|---|---|
| Local password login (no LDAP rule in `pg_hba.conf`) | Local DB Account | Local Authentication |
| AD/LDAP login, returned by the AD lookup | Non-Personal ID | Application Connection |
| AD/LDAP login, not returned by the AD lookup | Personal ID | Primary |

## Database setup (DBA, one time per cluster)

Roles are per cluster, so each EPAS cluster gets its own `sailpoint` database and runs its own feeds.

### 1. Create the account, database and schema

```bash
psql -h <host> -p 5444 -U enterprisedb -d edb -f sql/setup/01_create_sailpoint_db.sql
```

**Using a different username.** The feed account is called `sailpoint_feed` by default. To use
another name (for example to match your naming standard), pass it with `-v feed_user=`:

```bash
psql -h <host> -p 5444 -U enterprisedb -d edb -v feed_user=svc_sailpoint \
     -f sql/setup/01_create_sailpoint_db.sql
```

Then use that same name everywhere `sailpoint_feed` appears below: `PGUSER` in
`config/feeds.env`, the `pg_hba.conf` line, and `~/.pgpass`. The feed scripts themselves
read the name from `PGUSER`, so no code changes are needed.

This creates:

| Object | Name | Notes |
|---|---|---|
| Login role | `sailpoint_feed` | local password login; password set interactively |
| Database | `sailpoint` | owned by `sailpoint_feed`; `CONNECT` revoked from `PUBLIC` |
| Schema | `sailpoint` (in database `sailpoint`) | holds the views and their tables (`ad_npids`, `ad_users`, `feed_settings`), created by the scripts |

The last query in the script must return `sys | dba_users`. If it returns nothing, the EPAS
Oracle-compatibility views are missing in that database; check with:
`SHOW db_dialect; SHOW search_path;` and ask EDB support before continuing.

### 2. Add a `pg_hba.conf` entry

`sailpoint_feed` is a local password account, so it needs its own line that allows
password (`scram-sha-256`) login to the `sailpoint` database.

```
# TYPE    DATABASE   USER            ADDRESS            METHOD
# Scripts run on the database server itself (PGHOST="localhost" in feeds.env):
host      sailpoint  sailpoint_feed  127.0.0.1/32       scram-sha-256
# ...or, if PGHOST is left empty (Unix socket):
# local   sailpoint  sailpoint_feed                     scram-sha-256
# ...or, scripts run on a separate server, e.g. the multi-source central server
# (use its IP; hostssl requires SSL on the cluster):
# hostssl sailpoint  sailpoint_feed  10.20.30.40/32     scram-sha-256
```

- **Order matters.** `pg_hba.conf` uses the first line that matches. Put this line **above**
  any LDAP lines and any catch-all lines (`all all ...`); otherwise the feed account may be
  sent to LDAP and fail to log in.
- If the cluster still uses `md5` passwords (`SHOW password_encryption;`), use `md5` as the method.
- Reload and verify (no restart needed):

```sql
SELECT pg_reload_conf();
SELECT line_number, type, database, user_name, address, auth_method, error
FROM pg_hba_file_rules
WHERE 'sailpoint_feed' = ANY (user_name);   -- expect your line, with error empty
```

Do **not** add `sailpoint_feed` to an LDAP group or LDAP line: the account feed classifies it
as `Local DB Account` precisely because it authenticates locally.

## Server setup

See [docs/single_database.md](docs/single_database.md) or [docs/multi_source.md](docs/multi_source.md).

The `sailpoint_feed` account needs superuser or equivalent rights, because `pg_hba_file_rules`
and `sys.dba_users` are restricted views. The setup script grants superuser; a commented
least-privilege alternative is included in it.

## Views

The same feed logic is also available as database views in the `sailpoint` schema.
Multi-source mode extracts from them; single mode (`run_feeds.sh`) still runs the files in
`sql/`. Without a source code and AD data (always the case in single mode) the views return
exactly the same rows as those files, and DBAs and auditors can query them directly.

| View | Contents |
|---|---|
| `sailpoint.v_role_base` | shared logic: privilege rule, AD/local classification, status, dates |
| `sailpoint.v_access_feed` | Access feed, 12 columns |
| `sailpoint.v_account_feed_rows` | Account feed, one row per account per role (option 2) |
| `sailpoint.v_account_feed_combined` | Account feed, one row per account, roles joined by `\|` (option 1) |

Create or refresh them (safe to rerun; one transaction, so a failure changes nothing):

```bash
scripts/apply_views.sh
```

Run it once after the database setup, and again on every cluster whenever a file in
`sql/views/` changes (`scripts/central/apply_views_all.sh` does all clusters at once). The repo is the source of truth: never edit the views directly in the
database. Grants for a read-only role go in `sql/views/90_grants.sql`, because recreating the
views removes existing grants.

Example checks:

```sql
SELECT * FROM sailpoint.v_account_feed_combined WHERE "type" = 'Personal ID' ORDER BY "id";
SELECT "id", length("access") FROM sailpoint.v_account_feed_combined WHERE length("access") > 450;
```

Views have no guaranteed row order, so always add `ORDER BY`. Keep `sql/views/` and the
feed files in `sql/` in step: a rule changed in one must be changed in the other.

### Regression check

After changing anything in `sql/` or `sql/views/`, prove single mode is unaffected, on a
test cluster:

```bash
FEEDS_ENV=config/feeds.env scripts/check_views_match.sh    # expect MATCH three times
```

It compares the single-mode SQL files with the views byte for byte, inside a transaction that
is rolled back, so it changes nothing in the database.

## Open items before go-live

- [ ] **Account feed layout**: ask SailPoint whether they want one row per account (option 1)
      or one row per account × role (option 2). Single mode: `ACCOUNT_FEED_SQL` in
      `feeds.env`; multi-source: `ACCOUNT_LAYOUT` in `central.env`.
- [ ] **Multi-source ID format**: confirm `CODE:name` with SailPoint, and choose the source
      codes (4 characters or fewer, see docs/multi_source.md).
- [ ] **AD criteria**: ask the AD team how non-person accounts are identified (OU or attribute)
      and set `SEARCH_BASE` / `FILTER` (multi-source: `NPID_SEARCH_BASE` / `NPID_FILTER`).
- [ ] **Spelling**: confirm type/subtype values against the customer's ID types definition document.
- [ ] **Login name match**: the AD lookup assumes DB login name = AD `sAMAccountName`.
- [ ] **Option 1 only**: run the 450-character check at the end of the SQL file.
- [ ] **id length**: spec allows 32 characters; Postgres role names can be up to 63
      (multi-source mode refuses to publish longer IDs).
- [ ] After the first run, review `Personal ID` rows for service accounts the AD filter missed.

## Making changes

Work on a branch, open a pull request, and have a DBA review SQL changes before merging to `main`.
Run the regression check above for any SQL change. Tag each production release (`v1.0`,
`v1.1`, ...) so you can tell which version produced a feed; `v1.0-single` marks the last
version before multi-source mode was added.
To update the server: `cd /opt/edb-sailpoint-feeds && git pull` (or `git checkout <tag>`).
