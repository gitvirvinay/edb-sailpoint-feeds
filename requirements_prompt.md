# Requirements prompt

The input that describes this project in one message. Use it to rebuild or extend the repo
with an AI assistant, or to brief a new team member. Keep it up to date when a decision
changes. The field-by-field spec is in `docs/field_mapping.md`; attach that file with this prompt.

---

## Prompt

I need nightly **SailPoint access and account feeds as CSV files** from **EDB Postgres Advanced
Server (EPAS)**, used for user and role attestation. Deliver a GitHub-ready repo named
`edb-sailpoint-feeds`.

**Environment**
- EPAS in Oracle-compatible (redwood) mode; default database `edb`, superuser `enterprisedb`.
  Oracle-compatibility views such as `sys.dba_users` are available.
- The feeds run on a **Linux server with bash; no PowerShell**. `psql` and `ldapsearch` are available.
- Some database logins authenticate through **AD via LDAP** (rules in `pg_hba.conf`); others are
  pure local password accounts.
- **Both people and service accounts (non-person IDs) can be AD accounts.** Only AD can tell them
  apart. AD is large, so look up only the database's own login accounts in AD.
- Database login names match the AD `sAMAccountName`.

**Spec** (attached: `docs/field_mapping.md`)
- Access feed: 12 columns, one row per role that **cannot** log in (entitlements). `type` = `Role`.
  Include built-in `pg_*` roles, with the filter left commented so it can be switched back on.
- Account feed: 18 columns, one row per role that **can** log in. `access` is a foreign key to
  the Access feed `id`.

**Account type / subtype rules**

| Account | type | subtype |
|---|---|---|
| Local password login | Local DB Account | Local Authentication |
| AD login, identified by AD as non-person | Non-Personal ID | Application Connection |
| AD login, everyone else | Personal ID | Primary |

**Decisions already made**
- Dedicated database `sailpoint` with schema `sailpoint`, so nothing is stored in `edb`.
- Feed service account: default name `sailpoint_feed`, but the name must be configurable.
- Hosts, AD details and paths go in a config file kept out of Git; passwords go in `~/.pgpass`
  and a `chmod 600` file, never in the repo.
- One run script for cron that writes the CSVs safely (never half-written files) and stops with
  a clear message if something is missing.
- Include a one-time DBA setup script and the required `pg_hba.conf` entry in the README.
- Optional ShellCheck check via GitHub Actions. Linux line endings (`.gitattributes`).

**Still unknown (waiting on other teams)**
- SailPoint: one row per account (roles joined in `access`, which delimiter?) or one row per
  account x role? What should `access` be for an account with no roles?
- Exact type/subtype spelling from the customer's ID types definition document.
- AD team: how non-person accounts are identified (dedicated OU or an attribute such as `employeeType`).

**End product**
A repo I can push from Windows (Git installed) to my company's private GitHub organization,
then clone onto the Linux server and schedule with cron.

Ask me anything you need before you start.
