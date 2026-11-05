# Multi-source mode

Several EPAS clusters, combined into **one** Access file and **one** Account file, produced on
a central Linux server. For a single cluster, [single_database.md](single_database.md) is simpler.

## How it works

```
central server (cron)                          each EPAS cluster (database "sailpoint")
---------------------                          ----------------------------------------
1. read login names  ───────── psql ─────────▶ pg_roles
2. ONE AD lookup for all logins (ldapsearch)
3. per cluster, one transaction ─ psql ──────▶ load its AD rows into sailpoint.ad_users
                                               set its source code (sailpoint.feed_settings)
                                               check ID lengths
                              ◀──────────────  extract both feeds from the sailpoint views
4. combine (header once), publish atomically
```

No database is needed on the central server: each cluster joins its own data with the AD
rows, using the same views as single-database mode.

## What changes in the files

| Column | Single-database mode | Multi-source mode |
|---|---|---|
| Access `id`, Account `id`, Account `access` | `app_read` | `PRD1:app_read` |
| Access `displayName`, Account `name` | `app_read` | `app_read (PRD1)` |
| `accountCorrelationValue` | `alice` | `alice` (never prefixed: it links the account to a person) |
| `userFirstName`, `userLastName` | blank | from AD (`givenName`, `sn`) |
| `primaryOwner` | blank | AD `manager` of non-person accounts (its name, e.g. `Côté, Marc`) |
| `costCentre` | blank | AD `department` of non-person accounts |

The AD attributes used are set in `central.env`; set one to `""` to leave its column blank.
Non-person accounts are found the same way as in single mode (`NPID_SEARCH_BASE` + `NPID_FILTER`).

## Source codes

Each cluster gets a short code in `config/sources.conf`, used as the ID prefix.

- **3-5 characters, A-Z and 0-9. Use 4 or fewer** while built-in `pg_*` roles are in the feed:
  the longest one on Postgres 16, `pg_use_reserved_connections`, is 27 characters, so
  `PRD1:` (5) fits the 32-character `id` limit exactly and `PRD01:` (6) does not.
- **Never change a code once live.** SailPoint would see every account of that cluster as
  removed and re-added, losing attestation history.
- The run refuses to publish if any ID would exceed 32 characters, and names the IDs.

## Failure handling (tolerant)

| Situation | Result | Exit |
|---|---|---|
| all clusters and AD read | files published | 0 |
| a cluster cannot be read (down, views missing, ID too long) | its last good extract is reused, if not older than `MAX_STALE_HOURS` (48) | 1 |
| AD cannot be read | last AD data reused, if not older than 48 h | 1 |
| either of the above older than 48 h | **nothing published**, previous files untouched | 2 |
| a cluster's last good extract used the other account layout | not reused (would mix formats) | 2 |
| clusters return different columns (views out of date) | nothing published | 2 |
| another run still active | stops immediately | 2 |

Reported three ways: the log (stdout), the exit code, and `STATUS_FILE` (JSON, one entry per
cluster with status `FRESH` / `REUSED` / `FAILED`, age and message). Optional email: `MAIL_TO`.

Kept under `STATE_DIR`: `last_good/` (newest good extract per cluster and AD), `runs/<id>/`
(every run's work files and logs), `archive/<id>/` (gzipped copy of each published file).
Run folders and archives older than `KEEP_DAYS` (90) are deleted.

## Setup

### On every cluster (DBA, one time)

1. **Database setup** from the [README](../README.md) (feed account, `sailpoint` database).
2. **`pg_hba.conf`**: a `hostssl` line for the central server's IP, above any LDAP line:
   ```
   hostssl  sailpoint  sailpoint_feed  <central-server-ip>/32  scram-sha-256
   ```
   Then `SELECT pg_reload_conf();`

### On the central server (one time)

Requirements: `bash`, `psql` 12+, `ldapsearch`, `flock`, `gzip` (all standard on RHEL/Ubuntu).

```bash
git clone <repo-url> /opt/edb-sailpoint-feeds
cd /opt/edb-sailpoint-feeds
cp config/central.env.example  config/central.env   && chmod 600 config/central.env
cp config/sources.conf.example config/sources.conf
vi config/central.env           # AD, output folder, state folder, layout, email
vi config/sources.conf          # one line per cluster

# Passwords - never in the repo: one ~/.pgpass line per cluster, plus the AD bind password
echo 'pgprd01.example.com:5444:sailpoint:sailpoint_feed:<password>' >> ~/.pgpass
chmod 600 ~/.pgpass
printf '%s' '<ad-bind-password>' > ~/.ad_bind_pw && chmod 600 ~/.ad_bind_pw

sudo mkdir -p /var/lib/edb-sailpoint-feeds && sudo chown "$USER" /var/lib/edb-sailpoint-feeds

chmod +x scripts/*.sh scripts/central/*.sh
scripts/central/apply_views_all.sh      # create the views on every cluster
scripts/central/collect_all.sh          # test run
cat /var/lib/edb-sailpoint-feeds/status.json
```

Schedule it (daily at 01:30):

```
30 1 * * * /opt/edb-sailpoint-feeds/scripts/central/collect_all.sh >> /var/log/sailpoint_central.log 2>&1
```

## Day-to-day

| Task | Command |
|---|---|
| Add a cluster | DBA setup on it, add its line to `sources.conf` and `~/.pgpass`, then `scripts/central/apply_views_all.sh <CODE>` |
| Remove a cluster | delete its line from `sources.conf` (its accounts disappear from the next files) |
| Changed something in `sql/views/` | `scripts/central/apply_views_all.sh` (all clusters) |
| Check one cluster's views still match the SQL files | `FEEDS_ENV=<env for that cluster> scripts/check_views_match.sh` |
| What happened last night? | `status.json`, or `runs/<id>/<CODE>/error.log` under `STATE_DIR` |

## Security notes

- The central server holds credentials for every cluster: restrict who can log in to it and
  to the account that runs the job.
- Traffic crosses the network: keep `PGSSLMODE="require"` and use `hostssl` lines.
- Each cluster stores only its own logins' AD attributes (names, owner, cost centre) in
  `sailpoint.ad_users`.
- A least-privilege feed account (instead of superuser) is worth testing now: see the
  commented alternative in `sql/setup/01_create_sailpoint_db.sql`.
