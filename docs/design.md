# Design and decisions

Why the feeds work the way they do. Setup and operations are in the [README](../README.md).

## Shape

```
central server (cron)                                   each EPAS cluster (database "postgres")
---------------------                                   ---------------------------------------
pass 1, per cluster ───────────── psql ───────────────▶ classify logins from pg_hba_file_rules,
                                                        check, return each AD login's LDAP settings
AD lookups: one per distinct AD profile ── ldapsearch ─▶ the AD server/branch named in pg_hba.conf
pass 2, per cluster ───────────── psql ───────────────▶ load its AD rows (temp table), extract both
                    ◀─────────────────────────────────  feeds from temp views
combine (header once) and publish atomically
```

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Modes | Central multi-cluster only; one cluster = one line | one code path to maintain |
| Where the logic lives | SQL files in `sql/feed/`, sent each run; temporary objects only | no deploy step, nothing stored in clusters, no drift between repo and database |
| Shared rules | all in `10_base.sql` (temporary view `role_base`) | each rule defined once |
| Database connected to | `postgres` | catalogs are cluster-wide; nothing is created there |
| Local vs AD | the `pg_hba.conf` line that applies to the login | it is what Postgres itself uses |
| Person vs non-person | OU in that line's `ldapbasedn` (`OU=Person ID` / `OU=Non Person Id`) | the AD branch Postgres searches defines the account kind; follows OU moves automatically |
| AD connection | server, scheme/TLS, branch, bind DN, bind password, search attribute/filter read from that line | each cluster may use a different AD or branch; the lookup finds the same entry Postgres logs in as |
| AD passwords | read from `pg_hba_file_rules` each run; never stored, logged or put on a command line | nothing to keep in sync on the central server |
| IDs | `CODE:name` in `id` and `access`; `name (CODE)` in names; `accountCorrelationValue` unprefixed | unique across clusters; one person still correlates across clusters |
| Account layout | rows (one row per account per role) | SailPoint merges rows on `id` |
| Failures | runs are independent: any cluster or AD failure → nothing published, exit 2 | no stale data; auditors see exactly one night's state |
| History | run logs and gzipped published files, 90 days; never read by a run | audit trail only |

## Which pg_hba.conf line applies to a login

Postgres picks the first line matching the connection's type, database, user and address. The
feed cannot know the address or database a user will use, so it applies this rule:

1. Only network lines count (`host`, `hostssl`, `hostnossl`, `hostgssenc`, `hostnogssenc`).
   `local` (Unix socket) lines and lines with parse errors are ignored.
2. Among lines covering the login, prefer the one naming it **by name**; else by a `+group` it
   really belongs to (or a `/regex`, PG 16+); else by `all`. Within the same level, the first
   line wins. Every AD account has its own line, so the default `host all all 127.0.0.1/32 ...`
   lines at the top of the file do not hide it.
3. A login no line covers is reported as `Local DB Account` and listed in the run log.

Group membership is checked through `pg_auth_members` directly, not `pg_has_role()`, because
`pg_has_role()` treats a superuser as a member of every role and `pg_hba.conf` does not.

**Stops the cluster (and so the run):** an LDAP line with neither OU; an LDAP line without
`ldapbasedn` (simple bind, not supported); a login named on LDAP lines that point to different OUs.

**Limitation:** if one login were sent to different methods depending on the client address or
database, the feed reports the first line by the rule above. Not expected in this environment.

## AD lookup

- Profiles = distinct (server, port, scheme, TLS, base DN, bind DN, password, search attribute,
  search filter) across all clusters' AD logins. One `ldapsearch` session per profile; logins
  are batched (`AD_BATCH`) when the line uses `ldapsearchattribute`, and searched one by one
  when it uses `ldapsearchfilter` (with `$username` replaced, as Postgres does).
- `-x` (simple bind) is always used, as Postgres does; the password is passed with `-y` from a
  0600 file in a private folder deleted at the end of the run.
- Base64 values (accented names) are decoded; an owner DN becomes its CN (`Côté, Marc`).
- AD names fill `userFirstName` / `userLastName` for all AD accounts; `primaryOwner` and
  `costCentre` only for non-person accounts. Attributes are set in `central.env`.

## Security

- The feed account must read `pg_hba_file_rules`, which shows the AD bind passwords: it is
  superuser (or has the grants in the setup script). Connections use `hostssl` + `PGSSLMODE=require`.
- The central server holds the cluster passwords (`~/.pgpass`) and, during a run only, the AD
  bind passwords: restrict access to it and to the account running cron.
- AD names and per-cluster extracts exist only in the private run folder (deleted on exit) and
  in the published/archived files.

## Not done (on purpose)

- No comparison with earlier runs (row-count guards, reuse of earlier extracts): runs are independent.
- No objects in the clusters (no schema, views or tables).
- AD failure handling is strict for now (any AD failure stops the run); to be revisited.
