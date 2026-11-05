-- Session setup, run first in every session opened by scripts/collect_all.sh.
-- Everything the feed creates is TEMPORARY: it disappears when the session ends,
-- so nothing is ever stored in the cluster.

DO $$ BEGIN
    IF to_regclass('sys.dba_users') IS NULL THEN
        RAISE EXCEPTION 'view sys.dba_users not found in database % (EPAS Oracle-compatibility views missing)',
            current_database();
    END IF;
END $$;

-- AD attributes for this cluster's AD logins, loaded by collect_all.sh (empty in the first pass).
CREATE TEMP TABLE ad_users (
    login       text PRIMARY KEY,         -- lower-case login
    first_name  text,
    last_name   text,
    owner       text,                     -- name of the AD manager (used for non-person accounts)
    cost_centre text                      -- used for non-person accounts
);
