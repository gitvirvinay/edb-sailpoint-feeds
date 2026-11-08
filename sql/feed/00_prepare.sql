-- Session setup, run first in every session opened by scripts/collect_all.sh.
-- Everything the feed creates is TEMPORARY: it disappears when the session ends,
-- so nothing is ever stored in the cluster.

-- Safety check: is this the cluster sources.conf says it is? Each cluster's cluster_name
-- (postgresql.conf) must equal its code in sources.conf, so a wrong host or port can never
-- publish one cluster's accounts under another cluster's code. psql variables are not
-- expanded inside $$ ... $$, so the code is handed over through a session setting.
-- (\gset only keeps the result out of the run log.)
SELECT set_config('feed.source_code', :'source_code', false) AS source_code_check \gset

DO $$
DECLARE
    expected text := upper(current_setting('feed.source_code'));
    actual   text := upper(btrim(current_setting('cluster_name')));
BEGIN
    IF actual = '' THEN
        RAISE EXCEPTION 'cluster_name is not set on this cluster (expected %): set cluster_name = ''%'' in postgresql.conf and restart',
            expected, expected;
    ELSIF actual <> expected THEN
        RAISE EXCEPTION 'cluster_name is % but sources.conf expects %: wrong host or port in sources.conf, or wrong cluster_name',
            actual, expected;
    END IF;
END $$;

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
