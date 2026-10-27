# Field mapping

Source of each SailPoint column. "Spec" columns are transcribed from the SailPoint feed specification.

## Access feed (12 columns)

One row per role that cannot log in. Built-in `pg_*` roles are included (filter commented out in `sql/access_feed.sql`).

| # | Column | Mandatory | Spec says | Value / source |
|---|---|---|---|---|
| 1 | type | Y | Role / Group | `Role` (fixed) |
| 2 | id | Y | PostgreSQL rolname | `pg_roles.rolname` |
| 3 | displayName | Y | PostgreSQL rolname | `pg_roles.rolname` |
| 4 | description | Y | Role comment, otherwise "Database role &lt;rolname&gt;" | `COMMENT ON ROLE`, else default text |
| 5 | owner | N | NULL / enrichment | blank |
| 6 | attestable | Y | TRUE | `TRUE` |
| 7 | isDefault | Y | FALSE | `FALSE` |
| 8 | isRequestable | N | FALSE | `FALSE` |
| 9 | isPrivileged | Y | Derived from PostgreSQL privileged attributes/roles | TRUE if superuser, createrole, createdb, replication, bypassrls, or member of a powerful `pg_*` role |
| 10 | isElevated | N | FALSE currently | `FALSE` |
| 11 | childAccess | N | NULL currently | blank |
| 12 | createdDate | N | EPAS dba_users.created where available | `sys.dba_users.created` (usually blank for group roles) |

## Account feed (18 columns)

One row per login account (option 1) or per login account × role (option 2).

| # | Column | Mandatory | Data type | Spec description | Value / source |
|---|---|---|---|---|---|
| 1 | name | Y | nvarchar(128) | Account name | `rolname` |
| 2 | id | Y | nvarchar(32) | Primary key, unique account identifier | `rolname` |
| 3 | type | Y | nvarchar(max) | As defined in the ID types definition | see README classification table |
| 4 | subtype | Y | nvarchar(max) | As defined in the ID types definition | see README classification table |
| 5 | status | Y | nvarchar(max) | Active, Inactive, Locked | from `sys.dba_users.account_status` and `rolvaliduntil` |
| 6 | description | Y | nvarchar(max) | Generic for personal accounts; NPIDs need their purpose | `COMMENT ON ROLE`, else default text by type |
| 7 | accountCorrelationValue | Y | nvarchar(max) | Login ID or email used to link to a person | `rolname` (= AD `sAMAccountName` for LDAP users) |
| 8 | isPrivilegedFlag | Y | nvarchar(max) | Privileged per the ID types definition | same rule as Access feed `isPrivileged` |
| 9 | isLocked | N | nvarchar(max) | Account locked | TRUE if `account_status` contains LOCKED |
| 10 | userFirstName | N | nvarchar(max) | First name | blank (not stored in Postgres) |
| 11 | userLastName | N | nvarchar(max) | Last name | blank (not stored in Postgres) |
| 12 | primaryOwner | N | nvarchar(max) | Owner; may differ from user for NPIDs | blank (enrichment) |
| 13 | creationDate | N | nvarchar(max) | Date created | `sys.dba_users.created` |
| 14 | lastLoginDate | N | nvarchar(max) | Date of last login | blank (Postgres does not track it) |
| 15 | passwordLastChangeDate | N | nvarchar(max) | Date password last changed | blank (optional EPAS line commented in SQL) |
| 16 | disabledDate | N | nvarchar(max) | Date disabled | `lock_date`, `expiry_date` or `rolvaliduntil` |
| 17 | costCentre | N | nvarchar(max) | NPID cost centre | blank (enrichment) |
| 18 | access | Y | nvarchar(450) | Role or entitlement; foreign key to Access feed | role name(s) matching Access feed `id` |

Dates are formatted `YYYY-MM-DDTHH:MI:SS`. Booleans are `TRUE` / `FALSE`.
