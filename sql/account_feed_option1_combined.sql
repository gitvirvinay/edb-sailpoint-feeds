-- SailPoint ACCOUNT feed from EDB Postgres Advanced Server (EPAS)
-- OPTION 1: one row per login account; "access" lists all its roles joined by '|'
-- 18 columns per the SailPoint field spec. An account with no roles has "access" blank.
-- Run by scripts/run_feeds.sh (connection settings come from config/feeds.env).
-- Needs a superuser (or equivalent) service account: pg_hba_file_rules and dba_users are restricted views.

WITH RECURSIVE role_membership (member, roleid) AS (
    -- Real group membership, direct or inherited. Used for pg_hba.conf "+group" rules,
    -- because pg_hba.conf does NOT count a superuser as a member of every group
    -- (pg_has_role() would, and would wrongly mark superusers as LDAP logins).
    SELECT member, roleid FROM pg_auth_members
    UNION
    SELECT rm.member, am.roleid
    FROM role_membership rm
    JOIN pg_auth_members am ON am.member = rm.roleid
),
accts AS (
    SELECT
        r.oid,
        r.rolname,
        r.rolsuper, r.rolcreaterole, r.rolcreatedb, r.rolreplication, r.rolbypassrls,
        r.rolvaliduntil,
        u.account_status,                       -- EPAS: OPEN, LOCKED, EXPIRED, EXPIRED & LOCKED, LOCKED(TIMED) ...
        u.created,
        u.lock_date,
        u.expiry_date,
        -- TRUE when pg_hba.conf has an LDAP rule naming this user directly or via +group membership
        EXISTS (
            SELECT 1
            FROM pg_hba_file_rules h
            WHERE h.auth_method = 'ldap'
              AND (   r.rolname = ANY (h.user_name)
                   OR EXISTS (SELECT 1
                              FROM role_membership rm
                              JOIN pg_roles g ON g.oid = rm.roleid
                              WHERE rm.member = r.oid
                                AND '+' || g.rolname = ANY (h.user_name)))
        ) AS is_ldap
    FROM pg_roles r
    LEFT JOIN sys.dba_users u
           ON upper(u.username) = upper(r.rolname)                    -- sys. prefix: does not depend on search_path; names stored upper-case
    WHERE r.rolcanlogin                                               -- accounts = roles that can log in
),
memberships AS (
    SELECT DISTINCT member, roleid                                    -- DISTINCT: PG16+ can hold one row per grantor
    FROM pg_auth_members
),
ad_npids AS (                                                         -- AD/LDAP accounts that are NOT people (service IDs)
    SELECT rolname FROM sailpoint.ad_npids                            -- loaded nightly from AD by ad_npid_sync.sh
    -- VALUES ('svc_app1'), ('svc_etl')                               -- or list them by hand instead (replace the line above)
)
SELECT
    a.rolname                                    AS "name",                    -- (1)
    a.rolname                                    AS "id",                      -- (2) nvarchar(32): see note if names exceed 32 chars
    CASE
        WHEN NOT a.is_ldap                                   THEN 'Local DB Account'
        WHEN lower(a.rolname) IN (SELECT rolname FROM ad_npids)     THEN 'Non-Personal ID'
        ELSE 'Personal ID'
    END                                          AS "type",                    -- (3) confirm exact spelling against the ID types document
    CASE
        WHEN NOT a.is_ldap                                   THEN 'Local Authentication'
        WHEN lower(a.rolname) IN (SELECT rolname FROM ad_npids)     THEN 'Application Connection'
        ELSE 'Primary'
    END                                          AS "subtype",                 -- (4)
    CASE
        WHEN a.account_status ILIKE '%LOCKED%'            THEN 'Locked'
        WHEN a.account_status ILIKE 'EXPIRED%'
          OR a.rolvaliduntil < now()                      THEN 'Inactive'
        ELSE 'Active'
    END                                          AS "status",                  -- (5)
    COALESCE(shobj_description(a.oid, 'pg_authid'),
             CASE WHEN NOT a.is_ldap                               THEN 'Local database account ' || a.rolname
                  WHEN lower(a.rolname) IN (SELECT rolname FROM ad_npids)     THEN 'AD service account ' || a.rolname
                  ELSE 'Personal database account (AD/LDAP)' END)
                                                 AS "description",             -- (6) NPIDs: add COMMENT ON ROLE <name> IS '<purpose>'
    a.rolname                                    AS "accountCorrelationValue", -- (7) login ID; matches AD sAMAccountName for LDAP users
    CASE
        WHEN a.rolsuper OR a.rolcreaterole OR a.rolcreatedb
          OR a.rolreplication OR a.rolbypassrls
          OR EXISTS (
                SELECT 1
                FROM pg_roles p
                WHERE p.rolname IN ('pg_read_all_data', 'pg_write_all_data',
                                    'pg_read_server_files', 'pg_write_server_files',
                                    'pg_execute_server_program', 'pg_signal_backend',
                                    'pg_checkpoint', 'pg_monitor')
                  AND pg_has_role(a.oid, p.oid, 'MEMBER'))
        THEN 'TRUE' ELSE 'FALSE'
    END                                          AS "isPrivilegedFlag",        -- (8)
    CASE WHEN a.account_status ILIKE '%LOCKED%'
         THEN 'TRUE' ELSE 'FALSE' END            AS "isLocked",                -- (9)
    NULL::text                                   AS "userFirstName",           -- (10) not stored in Postgres
    NULL::text                                   AS "userLastName",            -- (11) not stored in Postgres
    NULL::text                                   AS "primaryOwner",            -- (12) enrichment (NPID owner)
    to_char(a.created, 'YYYY-MM-DD"T"HH24:MI:SS')
                                                 AS "creationDate",            -- (13)
    NULL::text                                   AS "lastLoginDate",           -- (14) Postgres does not track last login
    NULL::text                                   AS "passwordLastChangeDate",  -- (15) see note; LDAP users have no DB password
    -- to_char(pa.rolpasswordsetat, 'YYYY-MM-DD"T"HH24:MI:SS') AS "passwordLastChangeDate",  -- EPAS profiles; verify column exists, then join pg_authid pa
    to_char(CASE
                WHEN a.account_status ILIKE '%LOCKED%'  THEN a.lock_date
                WHEN a.account_status ILIKE 'EXPIRED%'  THEN a.expiry_date
                WHEN a.rolvaliduntil < now()            THEN a.rolvaliduntil
            END, 'YYYY-MM-DD"T"HH24:MI:SS')      AS "disabledDate",            -- (16)
    NULL::text                                   AS "costCentre",              -- (17) enrichment (NPIDs)
    (SELECT string_agg(g.rolname, '|' ORDER BY g.rolname)            -- change '|' to the delimiter SailPoint asks for
     FROM memberships m
     JOIN pg_roles    g ON g.oid = m.roleid
     WHERE m.member = a.oid
       -- AND g.rolname NOT LIKE 'pg\_%'                              -- uncomment to hide built-in pg_* roles (keep in sync with access feed)
    )                                            AS "access"                   -- (18) each value matches "id" in the Access feed; max 450 chars
FROM accts a
ORDER BY a.rolname;

-- Quick check: accounts whose combined role list would exceed the 450-character limit
--   SELECT r.rolname, length(string_agg(g.rolname, '|')) AS access_len
--   FROM pg_roles r JOIN pg_auth_members m ON m.member = r.oid JOIN pg_roles g ON g.oid = m.roleid
--   WHERE r.rolcanlogin GROUP BY r.rolname HAVING length(string_agg(g.rolname, '|')) > 450;
