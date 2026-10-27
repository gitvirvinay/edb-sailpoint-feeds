-- Account feed (18 columns), OPTION 1: one row per login account; "access" lists all its
-- roles joined by '|'. Built on the option 2 view, so both layouts always agree.
-- Same output as sql/account_feed_option1_combined.sql. Query with an ORDER BY, e.g.:
--     SELECT * FROM sailpoint.v_account_feed_combined ORDER BY "id";
-- Check the 450-character limit for "access":
--     SELECT "id", length("access") FROM sailpoint.v_account_feed_combined WHERE length("access") > 450;

CREATE VIEW sailpoint.v_account_feed_combined AS
SELECT
    "name", "id", "type", "subtype", "status", "description",
    "accountCorrelationValue", "isPrivilegedFlag", "isLocked",
    "userFirstName", "userLastName", "primaryOwner", "creationDate",
    "lastLoginDate", "passwordLastChangeDate", "disabledDate", "costCentre",
    string_agg("access", '|' ORDER BY "access")   AS "access"   -- change '|' to SailPoint's delimiter
FROM sailpoint.v_account_feed_rows
GROUP BY
    "name", "id", "type", "subtype", "status", "description",
    "accountCorrelationValue", "isPrivilegedFlag", "isLocked",
    "userFirstName", "userLastName", "primaryOwner", "creationDate",
    "lastLoginDate", "passwordLastChangeDate", "disabledDate", "costCentre";

COMMENT ON VIEW sailpoint.v_account_feed_combined IS
    'SailPoint Account feed, 18 columns, one row per account with roles joined by | (repo edb-sailpoint-feeds). Change the repo, then run scripts/apply_views.sh.';
