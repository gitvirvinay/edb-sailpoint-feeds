-- One-time setup on EVERY cluster, run by a DBA as superuser with psql:
--
--     psql -h <host> -p 5444 -U enterprisedb -d postgres -f sql/setup/01_create_feed_account.sql
--     psql ... -v feed_user=svc_sailpoint -f sql/setup/01_create_feed_account.sql   (other name)
--
-- Creates only the login account the central server connects with. The feed itself creates
-- nothing in the cluster: it uses temporary tables and views that vanish with its session.
-- Then add the pg_hba.conf line from README.md ("Cluster setup"). Needs psql 10 or later.

\set ON_ERROR_STOP on

\if :{?feed_user}
\else
    \set feed_user sailpoint_feed
\endif
\echo 'Feed account:' :feed_user

-- 1. Local password login (it must NOT be on an LDAP line in pg_hba.conf).
CREATE ROLE :"feed_user" LOGIN;
COMMENT ON ROLE :"feed_user" IS
    'NPID: central server account for the nightly SailPoint feeds (repo edb-sailpoint-feeds)';

-- Password set interactively, so it never appears in a file or shell history.
\echo 'Enter a password for' :feed_user '(store it in ~/.pgpass on the central server):'
\password :"feed_user"

-- 2. Rights. The feed reads pg_hba_file_rules (including the LDAP bind settings and
--    password of each line, to look users up in the right AD) and sys.dba_users.
--    Simplest: superuser. The account then shows isPrivilegedFlag = TRUE in its own row.
ALTER ROLE :"feed_user" SUPERUSER;

--    Least-privilege alternative (test on a non-production cluster first): remove the
--    ALTER ROLE line above and uncomment these.
-- GRANT EXECUTE ON FUNCTION pg_catalog.pg_hba_file_rules() TO :"feed_user";
-- GRANT SELECT  ON pg_catalog.pg_hba_file_rules           TO :"feed_user";
-- GRANT SELECT  ON sys.dba_users                          TO :"feed_user";

-- 3. Check the EPAS Oracle-compatibility view the feed needs is present in this database.
--    Expect one row: sys | dba_users. No rows = stop and investigate (see README).
SELECT n.nspname AS schema, c.relname AS view
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'sys' AND c.relname = 'dba_users';
