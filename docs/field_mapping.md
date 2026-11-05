# Field mapping

Source of each SailPoint column. "Spec" columns are transcribed from the SailPoint feed
specification. `CODE` is the cluster's code from `config/sources.conf` (e.g. `PRD1`).
Dates are formatted `YYYY-MM-DDTHH:MI:SS`; booleans are `TRUE` / `FALSE`.

## Access feed (12 columns): `sql/feed/30_access.sql`

One row per role that cannot log in, per cluster. Built-in `pg_*` roles are included
(filter commented out in the file).

| # | Column | Mandatory | Spec says | Value / source |
|---|---|---|---|---|
| 1 | type | Y | Role / Group | `Role` (fixed) |
| 2 | id | Y | PostgreSQL rolname | `CODE:rolname`, e.g. `PRD1:app_read` |
| 3 | displayName | Y | PostgreSQL rolname | `rolname (CODE)`, e.g. `app_read (PRD1)` |
| 4 | description | Y | Role comment, otherwise "Database role &lt;rolname&gt;" | `COMMENT ON ROLE`, else default text |
| 5 | owner | N | NULL / enrichment | blank |
| 6 | attestable | Y | TRUE | `TRUE` |
| 7 | isDefault | Y | FALSE | `FALSE` |
| 8 | isRequestable | N | FALSE | `FALSE` |
| 9 | isPrivileged | Y | Derived from PostgreSQL privileged attributes/roles | TRUE if superuser, createrole, createdb, replication, bypassrls, or member of a powerful `pg_*` role |
| 10 | isElevated | N | FALSE currently | `FALSE` |
| 11 | childAccess | N | NULL currently | blank |
| 12 | createdDate | N | EPAS dba_users.created where available | `sys.dba_users.created` (usually blank for group roles) |

## Account feed (18 columns): `sql/feed/31_account.sql`

One row per login account per role it holds, per cluster (an account without roles: one row,
`access` blank). SailPoint merges the rows on `id`.

| # | Column | Mandatory | Data type | Spec description | Value / source |
|---|---|---|---|---|---|
| 1 | name | Y | nvarchar(128) | Account name | `rolname (CODE)` |
| 2 | id | Y | nvarchar(32) | Primary key, unique account identifier | `CODE:rolname`; run refuses IDs over 32 characters |
| 3 | type | Y | nvarchar(max) | As defined in the ID types definition | from the login's `pg_hba.conf` line (see README) |
| 4 | subtype | Y | nvarchar(max) | As defined in the ID types definition | from the login's `pg_hba.conf` line (see README) |
| 5 | status | Y | nvarchar(max) | Active, Inactive, Locked | `sys.dba_users.account_status` and `rolvaliduntil` |
| 6 | description | Y | nvarchar(max) | Generic for personal accounts; NPIDs need their purpose | `COMMENT ON ROLE`, else default text by type |
| 7 | accountCorrelationValue | Y | nvarchar(max) | Login ID or email used to link to a person | `rolname`, never prefixed |
| 8 | isPrivilegedFlag | Y | nvarchar(max) | Privileged per the ID types definition | same rule as Access feed `isPrivileged` |
| 9 | isLocked | N | nvarchar(max) | Account locked | TRUE if `account_status` contains LOCKED |
| 10 | userFirstName | N | nvarchar(max) | First name | AD `givenName` (configurable), AD accounts |
| 11 | userLastName | N | nvarchar(max) | Last name | AD `sn` (configurable), AD accounts |
| 12 | primaryOwner | N | nvarchar(max) | Owner; may differ from user for NPIDs | non-person accounts: name of the AD `manager` |
| 13 | creationDate | N | nvarchar(max) | Date created | `sys.dba_users.created` |
| 14 | lastLoginDate | N | nvarchar(max) | Date of last login | blank (Postgres does not track it) |
| 15 | passwordLastChangeDate | N | nvarchar(max) | Date password last changed | blank |
| 16 | disabledDate | N | nvarchar(max) | Date disabled | `lock_date`, `expiry_date` or `rolvaliduntil` |
| 17 | costCentre | N | nvarchar(max) | NPID cost centre | non-person accounts: AD `department` (configurable) |
| 18 | access | Y | nvarchar(450) | Role or entitlement; foreign key to Access feed | `CODE:rolname` of each role held, = Access feed `id` |
