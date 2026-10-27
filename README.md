# EPAS → SailPoint feeds

Nightly CSV feeds from EDB Postgres Advanced Server (EPAS) for SailPoint user and role attestation:

| Feed | File | One row per | Columns |
|---|---|---|---|
| Access | `access_feed.csv` | Role that cannot log in (entitlement) | 12 |
| Account | `account_feed.csv` | Login account (or account × role, see below) | 18 |

## Repository layout

```
config/feeds.env.example   settings template (copy to feeds.env on the server; never commit feeds.env)
sql/access_feed.sql        Access feed query
sql/account_feed_option1_combined.sql   Account feed: one row per account, roles joined by '|'
sql/account_feed_option2_rows.sql       Account feed: one row per account per role
sql/setup/01_create_sailpoint_db.sql    one-time DBA setup: feed account, database, schema
scripts/ad_npid_sync.sh    looks up DB logins in AD, stores non-person IDs in sailpoint.ad_npids
scripts/run_feeds.sh       runs everything in order; call this from cron
docs/field_mapping.md      SailPoint column specs and where each value comes from
.github/workflows/         optional ShellCheck check on pull requests
```

## How it works

1. `ad_npid_sync.sh` reads the database's login accounts, asks AD which of them are
   non-person (service) accounts, and stores those names in `sailpoint.ad_npids`.
2. `access_feed.sql` lists the roles that cannot log in (entitlements).
3. The account feed lists login accounts, their status, privileges and roles, and classifies each one:

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
| Schema | `sailpoint` (in database `sailpoint`) | holds `sailpoint.ad_npids`, created by the sync script |

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
# ...or, scripts run on a separate server (use its IP; hostssl requires SSL on the cluster):
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

## Server setup (one time)

Requirements on the Linux server: `bash`, `psql` 12+, `ldapsearch`
(`sudo dnf install openldap-clients` or `sudo apt install ldap-utils`).

```bash
git clone <repo-url> /opt/epas-sailpoint-feeds
cd /opt/epas-sailpoint-feeds
cp config/feeds.env.example config/feeds.env
chmod 600 config/feeds.env
vi config/feeds.env            # fill in DB, AD and output settings

# Passwords - never in the repo
echo 'db-host:5444:sailpoint:sailpoint_feed:<password>' >> ~/.pgpass && chmod 600 ~/.pgpass
printf '%s' '<ad-bind-password>' > ~/.ad_bind_pw && chmod 600 ~/.ad_bind_pw

chmod +x scripts/*.sh
scripts/run_feeds.sh           # test run
```

Schedule it (daily at 02:00):

```
0 2 * * * /opt/epas-sailpoint-feeds/scripts/run_feeds.sh >> /var/log/sailpoint_feeds.log 2>&1
```

The `sailpoint_feed` account needs superuser or equivalent rights, because `pg_hba_file_rules`
and `sys.dba_users` are restricted views. The setup script grants superuser; a commented
least-privilege alternative is included in it.

If `run_feeds.sh` exits with code 3, `sys.dba_users` was not found in the `sailpoint`
database (see "Database setup" step 1).

## Open items before go-live

- [ ] **Account feed layout**: ask SailPoint whether they want one row per account (option 1)
      or one row per account × role (option 2). Set `ACCOUNT_FEED_SQL` in `feeds.env`,
      then delete the unused SQL file from the repo.
- [ ] **AD criteria**: ask the AD team how non-person accounts are identified (OU or attribute)
      and set `SEARCH_BASE` / `FILTER`.
- [ ] **Spelling**: confirm type/subtype values against the TD "Definition of ID Types" document.
- [ ] **Login name match**: the AD lookup assumes DB login name = AD `sAMAccountName`.
- [ ] **Option 1 only**: run the 450-character check at the end of the SQL file.
- [ ] **id length**: spec allows 32 characters; Postgres role names can be up to 63.
- [ ] After the first run, review `Personal ID` rows for service accounts the AD filter missed.

## Making changes

Work on a branch, open a pull request, and have a DBA review SQL changes before merging to `main`.
Tag each production release (`v1.0`, `v1.1`, ...) so you can tell which version produced a feed.
To update the server: `cd /opt/epas-sailpoint-feeds && git pull` (or `git checkout <tag>`).
