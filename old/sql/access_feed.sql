-- SailPoint ACCESS feed from EDB Postgres Advanced Server (EPAS)
-- One row per database role, 12 columns per the SailPoint field spec.
-- Run by scripts/run_feeds.sh (connection settings come from config/feeds.env).

SELECT
    'Role'                                       AS "type",              -- (1) all entitlements reported as Role
    r.rolname                                    AS "id",                -- (2)
    r.rolname                                    AS "displayName",       -- (3)
    COALESCE(shobj_description(r.oid, 'pg_authid'),
             'Database role ' || r.rolname)      AS "description",       -- (4) role comment, else default text
    NULL::text                                   AS "owner",             -- (5) NULL / enrichment
    'TRUE'                                       AS "attestable",        -- (6)
    'FALSE'                                      AS "isDefault",         -- (7)
    'FALSE'                                      AS "isRequestable",     -- (8)
    CASE
        WHEN r.rolsuper
          OR r.rolcreaterole
          OR r.rolcreatedb
          OR r.rolreplication
          OR r.rolbypassrls
          OR EXISTS (                                                    -- member (direct or inherited) of a powerful built-in role
                SELECT 1
                FROM pg_roles p
                WHERE p.rolname IN ('pg_read_all_data', 'pg_write_all_data',
                                    'pg_read_server_files', 'pg_write_server_files',
                                    'pg_execute_server_program', 'pg_signal_backend',
                                    'pg_checkpoint', 'pg_monitor')
                  AND pg_has_role(r.oid, p.oid, 'MEMBER'))
        THEN 'TRUE' ELSE 'FALSE'
    END                                          AS "isPrivileged",      -- (9)
    'FALSE'                                      AS "isElevated",        -- (10) FALSE currently
    NULL::text                                   AS "childAccess",       -- (11) NULL currently
    to_char(u.created, 'YYYY-MM-DD"T"HH24:MI:SS') AS "createdDate"       -- (12) EPAS dba_users.created where available
FROM pg_roles r
LEFT JOIN sys.dba_users u
       ON upper(u.username) = upper(r.rolname)                           -- sys. prefix: does not depend on search_path; names stored upper-case
WHERE NOT r.rolcanlogin                                                  -- entitlements only: roles that cannot log in
  -- AND r.rolname NOT LIKE 'pg\_%'                                      -- uncomment to skip built-in pg_* system roles
ORDER BY r.rolname;
