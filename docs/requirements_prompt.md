# Requirements prompt

The input that describes this project in one message. Use it to rebuild or extend the repo with
an AI assistant, or to brief a new team member. Keep it up to date when a decision changes. The
field-by-field spec is in `docs/field_mapping.md`; attach that file with this prompt.

---

## Prompt

I need nightly **SailPoint access and account feeds as CSV files** from several **EDB Postgres
Advanced Server (EPAS)** clusters, used for user and role attestation: **one combined Access
file and one combined Account file**. Deliver a GitHub-ready repo named `edb-sailpoint-feeds`.

**Environment**
- All sources are EPAS clusters in Oracle-compatible mode (`sys.dba_users` available).
- A central **Linux server with bash (no PowerShell)** reaches every cluster's port with `psql`
  and has `ldapsearch`. It does not host a database.
- Some logins authenticate locally (password), others through **AD via LDAP**. Every AD account
  has its **own line in `pg_hba.conf`**, using **search + bind** (`ldapbasedn`, `ldapbinddn`,
  `ldapbindpasswd`, `ldapsearchattribute` or `ldapsearchfilter`); no simple bind. Each cluster
  may use a different AD server or branch.
- The line's `ldapbasedn` tells the account kind: `OU=Person ID` = person,
  `OU=Non Person Id` = non-person (exact spelling).
- No user is sent to different methods depending on address or database.

**Spec** (attached: `docs/field_mapping.md`)
- Access feed: 12 columns, one row per role that **cannot** log in. `type` = `Role`. Include
  built-in `pg_*` roles, with a commented filter to leave them out.
- Account feed: 18 columns, one row per login account **per role** (rows layout). `access` is a
  foreign key to the Access feed `id`.

**Classification (from the `pg_hba.conf` line that applies to each login)**

| Line | type | subtype |
|---|---|---|
| ldap, `OU=Non Person Id` | Non-Personal ID | Application Connection |
| ldap, `OU=Person ID` | Personal ID | Primary |
| other method, or no line | Local DB Account | Local Authentication |

The line that applies: network lines only; prefer the line naming the login, then `+group`/regex,
then `all`. Stop with a clear message if an LDAP line has neither OU, has no `ldapbasedn`, or a
login is on LDAP lines with different OUs.

**Decisions already made**
- Central multi-cluster design only; one cluster = one line in `sources.conf`.
- Logic only in SQL files sent each run, using **temporary** tables and views: nothing is
  stored in the clusters and there is no deploy step. Connect to the `postgres` database.
- AD lookup per cluster's `pg_hba.conf` settings (read from `pg_hba_file_rules`, including the
  bind password, which is never stored, logged or passed on a command line); one lookup per
  distinct AD profile. Fill first/last name for AD accounts; owner (manager) and cost centre
  (department) for non-person accounts.
- IDs: `CODE:name` in `id` and `access`; names show `name (CODE)`; `accountCorrelationValue`
  never prefixed. Codes 3-5 characters A-Z/0-9 (4 or fewer advised), never changed once live;
  refuse to publish IDs over 32 characters.
- Runs are fully independent: any cluster or AD failure → nothing published, files already
  published left as they are, exit 2. No comparison with earlier runs.
- Reporting: log, exit code 0/2, `status.json`, optional email. Run logs and archived copies of
  published files kept 90 days, never read by a run.
- Feed account created by a one-time setup script (name configurable), superuser or
  least-privilege grants; `hostssl` line for the central server.
- Linux line endings (`.gitattributes`); optional ShellCheck check via GitHub Actions.

**Still unknown**
- SailPoint confirming the `CODE:name` ID format and the rows layout.
- Exact type/subtype spelling from the customer's ID types definition document.
- How AD failures should be handled (strict for now).

**End product**
A repo I can push from Windows (Git installed) to my company's private GitHub organization,
then clone onto the central Linux server and schedule with cron.

Ask me anything you need before you start, one question at a time.
