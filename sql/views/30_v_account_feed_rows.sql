-- Account feed (18 columns), OPTION 2: one row per login account per role it holds.
-- Accounts with no roles get one row with "access" blank.
-- Single mode: same output as sql/account_feed_option2_rows.sql.
-- Multi-source mode (source code set): "id" and "access" become CODE:name, "name" shows the
-- source, and AD names / owner / cost centre are filled from sailpoint.ad_users.
-- "accountCorrelationValue" is never prefixed: it links the account to a person.
-- Query with an ORDER BY, e.g.:
--     SELECT * FROM sailpoint.v_account_feed_rows ORDER BY "id", "access";

CREATE VIEW sailpoint.v_account_feed_rows AS
SELECT
    b.rolname || CASE WHEN b.source_code = '' THEN '' ELSE ' (' || b.source_code || ')' END
                                                  AS "name",                    -- (1)
    b.id_prefix || b.rolname                      AS "id",                      -- (2)
    b.account_type                                AS "type",                    -- (3)
    b.account_subtype                             AS "subtype",                 -- (4)
    b.status                                      AS "status",                  -- (5)
    coalesce(b.role_comment, b.default_description)
                                                  AS "description",             -- (6)
    b.rolname::text                               AS "accountCorrelationValue", -- (7)
    CASE WHEN b.is_privileged THEN 'TRUE' ELSE 'FALSE' END
                                                  AS "isPrivilegedFlag",        -- (8)
    CASE WHEN b.is_locked THEN 'TRUE' ELSE 'FALSE' END
                                                  AS "isLocked",                -- (9)
    b.first_name                                  AS "userFirstName",           -- (10) AD, multi-source mode
    b.last_name                                   AS "userLastName",            -- (11) AD, multi-source mode
    CASE WHEN b.is_ad_npid THEN b.ad_owner END    AS "primaryOwner",            -- (12) AD manager, NPIDs only
    to_char(b.created, 'YYYY-MM-DD"T"HH24:MI:SS') AS "creationDate",            -- (13)
    NULL::text                                    AS "lastLoginDate",           -- (14)
    NULL::text                                    AS "passwordLastChangeDate",  -- (15)
    to_char(b.disabled_at, 'YYYY-MM-DD"T"HH24:MI:SS')
                                                  AS "disabledDate",            -- (16)
    CASE WHEN b.is_ad_npid THEN b.ad_cost_centre END
                                                  AS "costCentre",              -- (17) AD, NPIDs only
    CASE WHEN g.rolname IS NOT NULL THEN b.id_prefix || g.rolname END
                                                  AS "access"                   -- (18) same prefix as Access "id"
FROM sailpoint.v_role_base b
LEFT JOIN (SELECT DISTINCT member, roleid FROM pg_auth_members) m   -- DISTINCT: PG16+ can hold one row per grantor
       ON m.member = b.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE b.rolcanlogin
  -- AND (g.rolname IS NULL OR g.rolname NOT LIKE 'pg\_%')          -- uncomment to hide built-in pg_* roles
;

COMMENT ON VIEW sailpoint.v_account_feed_rows IS
    'SailPoint Account feed, 18 columns, one row per account per role (repo edb-sailpoint-feeds). Change the repo, then run scripts/apply_views.sh.';
