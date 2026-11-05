-- One-time setup for the SailPoint feeds. Run by a DBA as superuser, with psql,
-- connected to the default database.
--
-- Default feed username (sailpoint_feed):
--     psql -h <host> -p 5444 -U enterprisedb -d edb -f sql/setup/01_create_sailpoint_db.sql
-- Your own feed username (use the same name as PGUSER in config/feeds.env):
--     psql -h <host> -p 5444 -U enterprisedb -d edb -v feed_user=svc_sailpoint \
--          -f sql/setup/01_create_sailpoint_db.sql
--
-- Then add the pg_hba.conf entry described in README.md ("Database setup").
-- Safe to run once; it stops on the first error. Needs psql 10 or later.

\set ON_ERROR_STOP on

-- Feed username: taken from -v feed_user=..., otherwise the default below.
\if :{?feed_user}
\else
    \set feed_user sailpoint_feed
\endif
\echo 'Feed account:' :feed_user

-- 1. Feed account: a local password login (the scripts connect with it nightly).
CREATE ROLE :"feed_user" LOGIN;
COMMENT ON ROLE :"feed_user" IS
    'NPID: produces the nightly SailPoint access and account CSV feeds (repo edb-sailpoint-feeds)';

-- Set its password interactively, so it never appears in a file or shell history.
\echo 'Enter a password for' :feed_user '(store it in ~/.pgpass on the feed server):'
\password :"feed_user"

-- 2. Rights to read the restricted catalog views the feeds use
--    (pg_hba_file_rules, sys.dba_users).
--    Simplest option: superuser. The account will then show isPrivilegedFlag = TRUE
--    in its own account feed row, which is correct and will be attested like any other.
ALTER ROLE :"feed_user" SUPERUSER;

--    Least-privilege alternative (test on a non-production cluster first): remove the
--    ALTER ROLE line above and uncomment these, plus the GRANT in step 4.
-- GRANT EXECUTE ON FUNCTION pg_catalog.pg_hba_file_rules() TO :"feed_user";
-- GRANT SELECT  ON pg_catalog.pg_hba_file_rules           TO :"feed_user";

-- 3. Dedicated database, owned by the feed account; nobody else may connect.
CREATE DATABASE sailpoint OWNER :"feed_user";
REVOKE CONNECT ON DATABASE sailpoint FROM PUBLIC;

-- 4. Inside the new database: schema for the feed's own table.
\connect sailpoint
CREATE SCHEMA IF NOT EXISTS sailpoint AUTHORIZATION :"feed_user";
-- GRANT SELECT ON sys.dba_users TO :"feed_user";     -- least-privilege alternative only

-- 5. Check the EPAS Oracle-compatibility view the feeds need is present here.
--    Expect one row: sys | dba_users. No rows = stop and investigate (see README).
SELECT n.nspname AS schema, c.relname AS view
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'sys' AND c.relname = 'dba_users';
