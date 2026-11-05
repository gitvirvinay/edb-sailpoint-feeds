-- Access feed, 12 columns: one row per role that cannot log in (entitlements).
-- TEMPORARY view; collect_all.sh exports it ordered by "id".

CREATE TEMP VIEW access_feed AS
SELECT
    'Role'::text                                  AS "type",              -- (1)
    id_prefix || rolname                          AS "id",                -- (2)  e.g. PRD1:app_read
    rolname || ' (' || source_code || ')'         AS "displayName",       -- (3)  e.g. app_read (PRD1)
    coalesce(role_comment, 'Database role ' || rolname)
                                                  AS "description",       -- (4)  COMMENT ON ROLE, else default
    NULL::text                                    AS "owner",             -- (5)  enrichment
    'TRUE'::text                                  AS "attestable",        -- (6)
    'FALSE'::text                                 AS "isDefault",         -- (7)
    'FALSE'::text                                 AS "isRequestable",     -- (8)
    CASE WHEN is_privileged THEN 'TRUE' ELSE 'FALSE' END
                                                  AS "isPrivileged",      -- (9)
    'FALSE'::text                                 AS "isElevated",        -- (10)
    NULL::text                                    AS "childAccess",       -- (11)
    to_char(created, 'YYYY-MM-DD"T"HH24:MI:SS')   AS "createdDate"        -- (12) sys.dba_users.created
FROM role_base
WHERE NOT rolcanlogin
  -- AND rolname NOT LIKE 'pg\_%'               -- uncomment to leave out built-in pg_* roles
;
