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
that disappear when the session ends, so what runs is always exactly what is in this repo. The
feed connects to a dedicated, empty `sailpoint` database on each cluster, so even those
temporary objects never touch `postgres` or `edb`.
**Runs are independent**: if any cluster or AD lookup fails, nothing is published and the files
already in the output folder stay as they are.

## Repository layout

```
config/central.env.example    settings for the central server (copy to central.env; never commit it)
config/sources.conf.example   one line per cluster (copy to sources.conf; never commit it)
sql/setup/01_setup_cluster.sql   one-time DBA setup on each cluster: feed account + empty sailpoint database
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

### 1. Create the feed account and the `sailpoint` database

```bash
psql -h <host> -p 5444 -U enterprisedb -d postgres -f sql/setup/01_setup_cluster.sql
# other name:  psql ... -v feed_user=svc_sailpoint -f sql/setup/01_setup_cluster.sql
# superuser:   psql ... -v superuser=on            -f sql/setup/01_setup_cluster.sql
```

(It connects to `postgres` only to issue `CREATE DATABASE`; nothing is created there.)

| Object | Name | Notes |
|---|---|---|
| Login role | `sailpoint_feed` | password asked interactively; **not** superuser by default: it gets read rights on `pg_hba_file_rules` (including the LDAP bind settings) and `sys.dba_users`, granted inside `sailpoint` (grants on these views apply only in the database they are made in) |
| Database | `sailpoint` | empty; owned by the feed account; `PUBLIC` has no access, so only the feed account (and superusers) can connect |

It ends with `Setup complete for sailpoint_feed in database sailpoint.` If it stops with
`sys.dba_users not found`, the EPAS Oracle-compatibility views are missing in the new database
(`SHOW db_dialect;`) and the feed cannot run there.

The script cannot be run twice. To start over after a failed run:
`DROP DATABASE IF EXISTS sailpoint; DROP ROLE IF EXISTS sailpoint_feed;`

### 2. Allow the central server in `pg_hba.conf`

```
# TYPE   DATABASE  USER            ADDRESS                  METHOD
hostssl  sailpoint  sailpoint_feed  <central-server-ip>/32   scram-sha-256
```

- Put it **above** any LDAP line and any `all` line: `pg_hba.conf` uses the first match.
- `hostssl`: the feed reads the AD bind passwords over this connection.
- Use `md5` instead if the cluster still stores md5 passwords (`SHOW password_encryption;`).
- Reload and verify: `SELECT pg_reload_conf();` then
  `SELECT line_number, address, auth_method, error FROM pg_hba_file_rules WHERE 'sailpoint_feed' = ANY (user_name);`

The feed account is itself a local account, so it appears in the Account feed as
`Local DB Account`, with `isPrivilegedFlag` = FALSE (TRUE if set up with `-v superuser=on`).
It can still read the AD bind passwords in `pg_hba.conf`, so attest it as a sensitive
service account like any other.

### 3. Set `cluster_name` to the cluster's code

Every run checks that each cluster really is the one `sources.conf` says it is: the cluster's
`cluster_name` must equal its code (case does not matter). This stops a wrong host or port in
`sources.conf` from publishing one cluster's accounts under another cluster's code.

```
# postgresql.conf (or a file in conf.d), then restart the cluster
cluster_name = 'PRD1'
```

Check with `SHOW cluster_name;`. `cluster_name` also appears in `ps` output and can be used in
`log_line_prefix`; if another tool already uses it with a different value, settle on one value first.

## Central server setup (one time)

The central server is the Linux machine that runs the feed every night. Set it up once; adding
a cluster later is one line in `sources.conf` and one line in `~/.pgpass`.

### 1. A dedicated OS account

Run the feed as a service account (e.g. `sailfeed`), not `root` and not a personal login: the
cluster passwords live in its `~/.pgpass`, and cron runs as this account.

```bash
sudo useradd -m sailfeed       # or ask the Linux team for a service account
sudo -iu sailfeed              # do the rest as this user
```

### 2. Tools

```bash
psql --version          # 12 or later
ldapsearch -VV          # openldap-clients (RHEL) / ldap-utils (Debian, Ubuntu)
which flock gzip mail   # mail only for email alerts
```

### 3. The repository

```bash
sudo mkdir -p /opt/edb-sailpoint-feeds && sudo chown sailfeed /opt/edb-sailpoint-feeds
git clone <repo-url> /opt/edb-sailpoint-feeds
cd /opt/edb-sailpoint-feeds
chmod +x scripts/*.sh
```

No GitHub access from the server? Copy the folder with `scp`; it works the same.

### 4. `config/central.env`

```bash
cp config/central.env.example config/central.env && chmod 600 config/central.env
vi config/central.env
```

| Setting | What to put |
|---|---|
| `PERSON_OU` / `NONPERSON_OU` | the OU names exactly as written in the `ldapbasedn` of your `pg_hba.conf` lines |
| `OUTPUT_DIR` | the folder SailPoint picks the files up from (ask the SailPoint team) |
| `LDAPTLS_CACERT` | uncomment if the AD lines use `ldaps://` or `ldaptls=1` with certificates from an internal CA |
| `MAIL_TO` | team address for alerts on failed runs; empty = no email |

No passwords go in this file, and it is in `.gitignore`.

### 5. `config/sources.conf`

```bash
cp config/sources.conf.example config/sources.conf
vi config/sources.conf
```

```
# CODE   HOST                    PORT
PRD1     pgprd01.example.com     5444
```

- CODE must equal the cluster's `cluster_name` (cluster setup, step 3).
- Write HOST the same way here and in `~/.pgpass`: `pgprd01` and `pgprd01.example.com` are
  different hosts to psql.

### 6. `~/.pgpass`: one line per cluster

No AD passwords are needed here: they come from `pg_hba.conf` at run time.

```bash
echo 'pgprd01.example.com:5444:sailpoint:sailpoint_feed:<password>' >> ~/.pgpass
chmod 600 ~/.pgpass            # psql ignores the file if it is readable by others
history -d $(history 1)        # remove that line (with the password) from shell history
```

Format: `host:port:database:user:password`.

### 7. State folder (run logs and archive)

```bash
sudo mkdir -p /var/lib/edb-sailpoint-feeds && sudo chown sailfeed /var/lib/edb-sailpoint-feeds
```

### 8. Checks before the first run (as `sailfeed`)

```bash
# Cluster login without a password prompt (-w): proves the .pgpass line matches. Prints the code.
psql -w "host=pgprd01.example.com port=5444 dbname=sailpoint user=sailpoint_feed sslmode=require" \
     -c "SHOW cluster_name;"

# AD server reachable (a server from ldapserver=... in pg_hba.conf). Prints namingContexts lines.
ldapsearch -x -H ldap://<ad-server>:389 -b "" -s base namingContexts | head
#   ldaps:  -H ldaps://<ad-server>:636
```

A password prompt or login error means the `.pgpass` line does not match host, port, database
and user exactly. A timeout on `ldapsearch` means a firewall between the central server and AD.

### 9. Test run

```bash
scripts/collect_all.sh; echo "exit code: $?"
cat /var/lib/edb-sailpoint-feeds/status.json
```

### 10. Schedule it with cron (daily at 01:30)

Cron runs jobs with a short PATH (`/usr/bin:/bin`), so add the folder that holds EDB's `psql`
(`which psql`) or the job fails with `psql: command not found`. Create the log file once as root:

```bash
sudo touch /var/log/sailpoint_feeds.log && sudo chown sailfeed /var/log/sailpoint_feeds.log
```

Then, as `sailfeed`, `crontab -e`:

```
PATH=/usr/edb/as16/bin:/usr/local/bin:/usr/bin:/bin
30 1 * * * /opt/edb-sailpoint-feeds/scripts/collect_all.sh >> /var/log/sailpoint_feeds.log 2>&1
```

Agree the time with the SailPoint team: the run must finish before they pick the files up.
To test, set the time a few minutes ahead, check `tail /var/log/sailpoint_feeds.log` ends with
`done: OK (exit 0)`, then set it back. Two runs never overlap (the script holds a lock).

Rotate the log (as root, `/etc/logrotate.d/sailpoint_feeds`); the detailed logs are in
`runs/` and are deleted after `KEEP_DAYS` anyway:

```
/var/log/sailpoint_feeds.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
}
```

Email (`MAIL_TO`) only reports runs that fail, not runs that never started. Have monitoring alert
when `status.json` is older than about 26 hours:
`find /var/lib/edb-sailpoint-feeds/status.json -mmin +1560` prints the file name if it is too old.

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
| `cluster_name is not set on this cluster` | set `cluster_name = 'CODE'` in postgresql.conf and restart |
| `cluster_name is X but sources.conf expects Y` | that `sources.conf` line points to the wrong host or port, or the cluster's `cluster_name` is wrong |

## Open items

- [ ] SailPoint: confirm the `CODE:name` ID format and the rows layout of the Account file.
- [ ] Type/subtype spelling against the customer's ID types definition document.
- [ ] AD failure handling: today any AD failure stops the run (to revisit).
- [x] Least-privilege feed account: now the default in the setup script (`-v superuser=on` for the old behaviour).

## Making changes

Work on a branch, open a pull request, and have a DBA review SQL changes before merging to
`main`. Tag each production release (`v2.0`, `v2.1`, ...) so you can tell which version produced
a feed. Update the server with `git pull` (or `git checkout <tag>`); there is nothing to deploy
to the clusters.
