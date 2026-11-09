-- One-time setup on EVERY cluster, run by a DBA as superuser with psql:
--
--     psql -h <host> -p 5444 -U enterprisedb -d postgres -f sql/setup/01_setup_cluster.sql
--     psql ... -v feed_user=svc_sailpoint -f sql/setup/01_setup_cluster.sql   (other account name)
--     psql ... -v superuser=on            -f sql/setup/01_setup_cluster.sql   (superuser instead of grants)
--
-- It connects to "postgres" only to issue CREATE DATABASE; nothing is created there.
-- Creates:
--   * the login account the central server connects with
--   * an EMPTY database "sailpoint" that only this account may use. Each nightly session
--     connects there, so its temporary tables and views never touch postgres or edb.
--     Nothing permanent is ever created in it.
-- Then add the pg_hba.conf line and set cluster_name (README, "Cluster setup"). Needs psql 10 or later.

\set ON_ERROR_STOP on

\if :{?feed_user}
\else
    \set feed_user sailpoint_feed
\endif
\if :{?superuser}
\else
    \set superuser off
\endif
\echo 'Feed account:' :feed_user '  superuser:' :superuser

-- 1. Local password login (it must NOT be on an LDAP line in pg_hba.conf).
CREATE ROLE :"feed_user" LOGIN;
COMMENT ON ROLE :"feed_user" IS
    'NPID: central server account for the nightly SailPoint feeds (repo edb-sailpoint-feeds)';

-- Password set interactively, so it never appears in a file or shell history.
\echo 'Enter a password for' :feed_user '(store it in ~/.pgpass on the central server):'
\password :"feed_user"

-- 2. Rights. The feed reads pg_hba_file_rules (including the LDAP bind settings and
--    password of each line, to look users up in the right AD) and sys.dba_users.
--    Default: least privilege, with grants in step 4 below.
--    -v superuser=on: superuser instead (the account then shows isPrivilegedFlag = TRUE).
\if :superuser
    ALTER ROLE :"feed_user" SUPERUSER;
\endif

-- 3. The dedicated, empty database. Its owner (the feed account) can connect and create
--    temporary objects; nobody else gets any access.
CREATE DATABASE sailpoint OWNER :"feed_user";
REVOKE ALL ON DATABASE sailpoint FROM PUBLIC;
COMMENT ON DATABASE sailpoint IS
    'Empty landing database for the nightly SailPoint feeds (temporary objects only). Repo edb-sailpoint-feeds.';

-- 4. Inside the new database: check the EPAS Oracle-compatibility view the feed needs, then
--    grant read access. The grants MUST be made here: pg_hba_file_rules and sys.dba_users
--    exist separately in every database, and a grant only covers the copy in the database
--    it is made in.
\connect sailpoint
DO $$ BEGIN
    IF to_regclass('sys.dba_users') IS NULL THEN
        RAISE EXCEPTION 'sys.dba_users not found in database sailpoint: EPAS Oracle-compatibility views missing (SHOW db_dialect;), the feed cannot run on this cluster';
    END IF;
END $$;

\if :superuser
\else
    GRANT EXECUTE ON FUNCTION pg_catalog.pg_hba_file_rules() TO :"feed_user";
    GRANT SELECT  ON pg_catalog.pg_hba_file_rules            TO :"feed_user";
    GRANT USAGE   ON SCHEMA sys                              TO :"feed_user";   -- usually PUBLIC already
    GRANT SELECT  ON sys.dba_users                           TO :"feed_user";
\endif

\echo 'Setup complete for' :feed_user 'in database sailpoint.'
