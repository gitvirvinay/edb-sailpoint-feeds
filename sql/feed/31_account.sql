-- Account feed, 18 columns: one row per login account per role it holds
-- (accounts without roles: one row, "access" blank). SailPoint merges rows on "id".
-- TEMPORARY view; collect_all.sh exports it ordered by "id", "access".

CREATE TEMP VIEW account_feed AS
SELECT
    b.rolname || ' (' || b.source_code || ')'     AS "name",                    -- (1)  e.g. alice (PRD1)
    b.id_prefix || b.rolname                      AS "id",                      -- (2)  e.g. PRD1:alice
    b.account_type                                AS "type",                    -- (3)
    b.account_subtype                             AS "subtype",                 -- (4)
    b.status                                      AS "status",                  -- (5)
    coalesce(b.role_comment, b.default_description)
                                                  AS "description",             -- (6)  NPIDs: COMMENT ON ROLE <name> IS '<purpose>'
    b.rolname::text                               AS "accountCorrelationValue", -- (7)  never prefixed: links to a person
    CASE WHEN b.is_privileged THEN 'TRUE' ELSE 'FALSE' END
                                                  AS "isPrivilegedFlag",        -- (8)
    CASE WHEN b.is_locked THEN 'TRUE' ELSE 'FALSE' END
                                                  AS "isLocked",                -- (9)
    b.first_name                                  AS "userFirstName",           -- (10) AD
    b.last_name                                   AS "userLastName",            -- (11) AD
    CASE WHEN b.is_npid THEN b.ad_owner END       AS "primaryOwner",            -- (12) AD manager, NPIDs only
    to_char(b.created, 'YYYY-MM-DD"T"HH24:MI:SS') AS "creationDate",            -- (13) sys.dba_users.created
    NULL::text                                    AS "lastLoginDate",           -- (14) not tracked by Postgres
    NULL::text                                    AS "passwordLastChangeDate",  -- (15) not available
    to_char(b.disabled_at, 'YYYY-MM-DD"T"HH24:MI:SS')
                                                  AS "disabledDate",            -- (16)
    CASE WHEN b.is_npid THEN b.ad_cost_centre END AS "costCentre",              -- (17) AD, NPIDs only
    CASE WHEN g.rolname IS NOT NULL THEN b.id_prefix || g.rolname END
                                                  AS "access"                   -- (18) = Access feed "id"
FROM role_base b
LEFT JOIN (SELECT DISTINCT member, roleid FROM pg_auth_members) m   -- DISTINCT: PG16+ may list a grant per grantor
       ON m.member = b.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE b.rolcanlogin
  -- AND (g.rolname IS NULL OR g.rolname NOT LIKE 'pg\_%')   -- uncomment to leave out built-in pg_* roles
;
