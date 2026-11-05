# Single-database mode

One EPAS cluster, feeds produced by a script running on (or next to) that cluster.
For several clusters combined into one pair of files, see [multi_source.md](multi_source.md).

Before this: do the one-time **Database setup** in the [README](../README.md) on the cluster.

## How it runs

`scripts/run_feeds.sh` (from cron) does, in order:

1. `scripts/ad_npid_sync.sh`: asks AD which of the database's logins are non-person
   accounts and stores them in `sailpoint.ad_npids`.
2. `sql/access_feed.sql` → `access_feed.csv`
3. The account feed chosen by `ACCOUNT_FEED_SQL` → `account_feed.csv`

Each CSV is written to a temporary file and renamed only when complete. If any step fails,
the script stops and the previous CSVs stay in place.

## Server setup (one time)

Requirements on the Linux server: `bash`, `psql` 12+, `ldapsearch`
(`sudo dnf install openldap-clients` or `sudo apt install ldap-utils`).

```bash
git clone <repo-url> /opt/edb-sailpoint-feeds
cd /opt/edb-sailpoint-feeds
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
0 2 * * * /opt/edb-sailpoint-feeds/scripts/run_feeds.sh >> /var/log/sailpoint_feeds.log 2>&1
```

## Exit codes

| Code | Meaning |
|---|---|
| 0 | both files written |
| 2 | config file missing |
| 3 | `sys.dba_users` not found in the `sailpoint` database (see README, Database setup step 1) |
| other | a step failed (AD lookup, query, file write); previous files unchanged |

## Settings to decide before go-live

- `ACCOUNT_FEED_SQL` in `feeds.env`: `account_feed_option2_rows.sql` (one row per account per
  role) or `account_feed_option1_combined.sql` (one row per account, roles joined by `|`).
- `SEARCH_BASE` / `FILTER`: how AD identifies non-person accounts.
- Option 1 only: run the 450-character check at the end of its SQL file.
