-- Access feed (12 columns): one row per role that cannot log in (entitlements).
-- Single mode: same output as sql/access_feed.sql.
-- Multi-source mode (source code set): "id" becomes CODE:rolname and "displayName" shows
-- the source, e.g. "app_read (PRD01)".
-- Query with an ORDER BY, e.g.:
--     SELECT * FROM sailpoint.v_access_feed ORDER BY "id";

CREATE VIEW sailpoint.v_access_feed AS
SELECT
    'Role'::text                                  AS "type",              -- (1)
    id_prefix || rolname                          AS "id",                -- (2)
    rolname || CASE WHEN source_code = '' THEN '' ELSE ' (' || source_code || ')' END
                                                  AS "displayName",       -- (3)
    coalesce(role_comment, 'Database role ' || rolname)
                                                  AS "description",       -- (4)
    NULL::text                                    AS "owner",             -- (5) enrichment
    'TRUE'::text                                  AS "attestable",        -- (6)
    'FALSE'::text                                 AS "isDefault",         -- (7)
    'FALSE'::text                                 AS "isRequestable",     -- (8)
    CASE WHEN is_privileged THEN 'TRUE' ELSE 'FALSE' END
                                                  AS "isPrivileged",      -- (9)
    'FALSE'::text                                 AS "isElevated",        -- (10)
    NULL::text                                    AS "childAccess",       -- (11)
    to_char(created, 'YYYY-MM-DD"T"HH24:MI:SS')   AS "createdDate"        -- (12)
FROM sailpoint.v_role_base
WHERE NOT rolcanlogin
  -- AND rolname NOT LIKE 'pg\_%'                                         -- uncomment to skip built-in pg_* roles
;

COMMENT ON VIEW sailpoint.v_access_feed IS
    'SailPoint Access feed, 12 columns (repo edb-sailpoint-feeds). Change the repo, then run scripts/apply_views.sh.';
