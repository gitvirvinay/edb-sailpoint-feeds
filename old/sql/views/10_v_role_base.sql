-- Base view: one row per role (login accounts and non-login roles alike).
-- Holds the logic shared by every feed, so each rule is defined in ONE place:
--   * is_privileged       the "privileged role" rule (Access isPrivileged / Account isPrivilegedFlag)
--   * is_ldap             does pg_hba.conf send this login to LDAP/AD?
--   * is_ad_npid          did the AD lookup (ad_npid_sync.sh) mark it as a non-person ID?
--   * account_type / account_subtype   the classification used by the account feed
--   * status, is_locked, disabled_at   account state from EPAS sys.dba_users
-- Feed views (20_..., 30_..., 31_...) only rename and format these columns.

CREATE VIEW sailpoint.v_role_base AS
WITH RECURSIVE role_membership (member, roleid) AS (
    -- Real group membership, direct or inherited. Used for pg_hba.conf "+group" rules,
    -- because pg_hba.conf does NOT count a superuser as a member of every group
    -- (pg_has_role() would, and would wrongly mark superusers as LDAP logins).
    SELECT member, roleid FROM pg_auth_members
    UNION
    SELECT rm.member, am.roleid
    FROM role_membership rm
    JOIN pg_auth_members am ON am.member = rm.roleid
),
roles AS (
    SELECT
        r.oid,
        r.rolname,
        r.rolcanlogin,
        r.rolvaliduntil,
        shobj_description(r.oid, 'pg_authid')               AS role_comment,
        u.account_status,                                    -- EPAS: OPEN, LOCKED, EXPIRED, EXPIRED & LOCKED, LOCKED(TIMED) ...
        u.created,
        u.lock_date,
        u.expiry_date,
        (   r.rolsuper OR r.rolcreaterole OR r.rolcreatedb
         OR r.rolreplication OR r.rolbypassrls
         OR EXISTS (                                         -- member (direct or inherited) of a powerful built-in role
                SELECT 1
                FROM pg_roles p
                WHERE p.rolname IN ('pg_read_all_data', 'pg_write_all_data',
                                    'pg_read_server_files', 'pg_write_server_files',
                                    'pg_execute_server_program', 'pg_signal_backend',
                                    'pg_checkpoint', 'pg_monitor')
                  AND pg_has_role(r.oid, p.oid, 'MEMBER'))
        )                                                    AS is_privileged,
        (   r.rolcanlogin
         AND EXISTS (                                        -- an LDAP rule names this user directly or via +group
                SELECT 1
                FROM pg_hba_file_rules h
                WHERE h.auth_method = 'ldap'
                  AND (   r.rolname = ANY (h.user_name)
                       OR EXISTS (SELECT 1
                                  FROM role_membership rm
                                  JOIN pg_roles g ON g.oid = rm.roleid
                                  WHERE rm.member = r.oid
                                    AND '+' || g.rolname = ANY (h.user_name))))
        )                                                    AS is_ldap
    FROM pg_roles r
    LEFT JOIN sys.dba_users u
           ON upper(u.username) = upper(r.rolname)           -- sys. prefix: independent of search_path; names stored upper-case
),
classified AS (
    SELECT
        roles.*,
        (roles.is_ldap
         AND lower(roles.rolname) IN (SELECT rolname FROM sailpoint.ad_npids)) AS is_ad_npid,
        (roles.account_status ILIKE '%LOCKED%')              AS is_locked_raw,
        (roles.account_status ILIKE 'EXPIRED%'
         OR roles.rolvaliduntil < now())                     AS is_expired
    FROM roles
)
SELECT
    oid,
    rolname,
    rolcanlogin,
    role_comment,
    created,
    is_privileged,
    is_ldap,
    is_ad_npid,
    -- Classification (login accounts only; NULL for non-login roles).
    -- Confirm exact spelling against the ID types definition document.
    CASE WHEN NOT rolcanlogin THEN NULL
         WHEN NOT is_ldap     THEN 'Local DB Account'
         WHEN is_ad_npid      THEN 'Non-Personal ID'
         ELSE                      'Personal ID'
    END                                                      AS account_type,
    CASE WHEN NOT rolcanlogin THEN NULL
         WHEN NOT is_ldap     THEN 'Local Authentication'
         WHEN is_ad_npid      THEN 'Application Connection'
         ELSE                      'Primary'
    END                                                      AS account_subtype,
    CASE WHEN NOT rolcanlogin THEN NULL
         WHEN NOT is_ldap     THEN 'Local database account ' || rolname
         WHEN is_ad_npid      THEN 'AD service account ' || rolname
         ELSE                      'Personal database account (AD/LDAP)'
    END                                                      AS default_description,
    CASE WHEN coalesce(is_locked_raw, false) THEN 'Locked'
         WHEN coalesce(is_expired, false)    THEN 'Inactive'
         ELSE                                     'Active'
    END                                                      AS status,
    coalesce(is_locked_raw, false)                           AS is_locked,
    CASE WHEN coalesce(is_locked_raw, false)        THEN lock_date
         WHEN account_status ILIKE 'EXPIRED%'       THEN expiry_date
         WHEN rolvaliduntil < now()                 THEN rolvaliduntil
    END                                                      AS disabled_at
FROM classified;

COMMENT ON VIEW sailpoint.v_role_base IS
    'Shared logic for the SailPoint feeds (repo edb-sailpoint-feeds, sql/views). Do not edit in the database; change the repo and run scripts/apply_views.sh.';
