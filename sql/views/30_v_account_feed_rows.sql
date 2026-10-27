-- Account feed (18 columns), OPTION 2: one row per login account per role it holds.
-- Accounts with no roles get one row with "access" blank.
-- Same output as sql/account_feed_option2_rows.sql. Query with an ORDER BY, e.g.:
--     SELECT * FROM sailpoint.v_account_feed_rows ORDER BY "id", "access";

CREATE VIEW sailpoint.v_account_feed_rows AS
SELECT
    b.rolname::text                               AS "name",                    -- (1)
    b.rolname::text                               AS "id",                      -- (2)
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
    NULL::text                                    AS "userFirstName",           -- (10)
    NULL::text                                    AS "userLastName",            -- (11)
    NULL::text                                    AS "primaryOwner",            -- (12)
    to_char(b.created, 'YYYY-MM-DD"T"HH24:MI:SS') AS "creationDate",            -- (13)
    NULL::text                                    AS "lastLoginDate",           -- (14)
    NULL::text                                    AS "passwordLastChangeDate",  -- (15)
    to_char(b.disabled_at, 'YYYY-MM-DD"T"HH24:MI:SS')
                                                  AS "disabledDate",            -- (16)
    NULL::text                                    AS "costCentre",              -- (17)
    g.rolname::text                               AS "access"                   -- (18)
FROM sailpoint.v_role_base b
LEFT JOIN (SELECT DISTINCT member, roleid FROM pg_auth_members) m   -- DISTINCT: PG16+ can hold one row per grantor
       ON m.member = b.oid
LEFT JOIN pg_roles g ON g.oid = m.roleid
WHERE b.rolcanlogin
  -- AND (g.rolname IS NULL OR g.rolname NOT LIKE 'pg\_%')          -- uncomment to hide built-in pg_* roles
;

COMMENT ON VIEW sailpoint.v_account_feed_rows IS
    'SailPoint Account feed, 18 columns, one row per account per role (repo edb-sailpoint-feeds). Change the repo, then run scripts/apply_views.sh.';
