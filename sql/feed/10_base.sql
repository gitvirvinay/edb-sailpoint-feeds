-- role_base: one row per role, with every rule the feeds share, defined in ONE place.
-- A TEMPORARY view: it exists only for this session (nothing is stored in the cluster).
--
-- psql variables, passed by scripts/collect_all.sh:
--   source_code    the cluster's code, e.g. PRD1 (becomes the "PRD1:" ID prefix)
--   person_ou      OU name marking person accounts,     e.g. Person ID
--   nonperson_ou   OU name marking non-person accounts, e.g. Non Person Id
--
-- How each login is classified, from pg_hba.conf (via pg_hba_file_rules):
--   * Only network lines count (host, hostssl, hostnossl, hostgssenc, hostnogssenc);
--     "local" (Unix socket) lines and lines with errors are ignored.
--   * The line that applies to a login is the first line that names it, in this order of
--     preference: by its own name; else by a +group it really belongs to (or a /regex);
--     else by "all". (Every AD account has its own line, so the default "host all all
--     127.0.0.1/32" lines at the top of the file do not hide it.)
--   * That line's method decides:
--       ldap, ldapbasedn with OU=<nonperson_ou>  -> Non-Personal ID / Application Connection
--       ldap, ldapbasedn with OU=<person_ou>     -> Personal ID / Primary
--       any other method, or no line at all      -> Local DB Account / Local Authentication
--   * Errors (the cluster is not published, see 20_checks.sql):
--       ldap line with neither OU; ldap line without ldapbasedn (simple bind);
--       one login named on LDAP lines that point to different OUs.

CREATE TEMP VIEW role_base AS
WITH RECURSIVE role_membership (member, roleid) AS (
    -- Real group membership, direct or inherited. pg_has_role() is NOT used for this:
    -- it treats a superuser as a member of every role, pg_hba.conf does not.
    SELECT member, roleid FROM pg_auth_members
    UNION
    SELECT rm.member, am.roleid
    FROM role_membership rm
    JOIN pg_auth_members am ON am.member = rm.roleid
),
settings AS (
    SELECT :'source_code'::text AS source_code,
           -- OU names as regular expressions matching one whole DN component,
           -- so "Person ID" never matches inside "Non Person Id".
           '(^|,)[[:space:]]*ou[[:space:]]*=[[:space:]]*'
             || regexp_replace(lower(trim(:'person_ou')), '([!$()*+.:<=>?[\\\]^{|}-])', '\\\1', 'g')
             || '[[:space:]]*(,|$)'                                  AS person_re,
           '(^|,)[[:space:]]*ou[[:space:]]*=[[:space:]]*'
             || regexp_replace(lower(trim(:'nonperson_ou')), '([!$()*+.:<=>?[\\\]^{|}-])', '\\\1', 'g')
             || '[[:space:]]*(,|$)'                                  AS nonperson_re
),
hba AS (
    SELECT h.line_number,
           h.user_name,
           h.auth_method,
           (SELECT substr(o, length('ldapbasedn=') + 1)
            FROM unnest(coalesce(h.options, '{}'::text[])) o
            WHERE o LIKE 'ldapbasedn=%' LIMIT 1)                     AS basedn
    FROM pg_hba_file_rules h
    WHERE h.type IN ('host', 'hostssl', 'hostnossl', 'hostgssenc', 'hostnogssenc')
      AND h.error IS NULL
      AND h.database IS DISTINCT FROM ARRAY['replication']
),
matches AS (
    -- Every network line that covers each login, with how specifically it names it:
    -- 1 = by name, 2 = by +group or /regex, 3 = by "all".
    SELECT r.oid, h.line_number, h.auth_method, h.basedn,
           CASE
               WHEN r.rolname = ANY (h.user_name) THEN 1
               WHEN EXISTS (SELECT 1 FROM role_membership rm JOIN pg_roles g ON g.oid = rm.roleid
                            WHERE rm.member = r.oid AND '+' || g.rolname = ANY (h.user_name))
                 OR EXISTS (SELECT 1 FROM unnest(h.user_name) u
                            WHERE u LIKE '/%' AND r.rolname ~ substr(u, 2)) THEN 2
               WHEN 'all' = ANY (h.user_name) THEN 3
           END                                                       AS specificity
    FROM pg_roles r
    JOIN hba h ON true
    WHERE r.rolcanlogin
),
line_classes AS (
    SELECT m.*,
           CASE
               WHEN m.auth_method <> 'ldap'                THEN 'LOCAL'
               WHEN m.basedn IS NULL                       THEN 'SIMPLE_BIND'
               WHEN lower(m.basedn) ~ s.nonperson_re       THEN 'NONPERSON'
               WHEN lower(m.basedn) ~ s.person_re          THEN 'PERSON'
               ELSE                                             'UNKNOWN_OU'
           END                                               AS line_class
    FROM matches m CROSS JOIN settings s
    WHERE m.specificity IS NOT NULL
),
chosen_line AS (
    SELECT DISTINCT ON (oid) oid, line_number, line_class
    FROM line_classes
    ORDER BY oid, specificity, line_number
),
conflicts AS (
    -- A login named on several LDAP lines that point to different OUs.
    SELECT oid, string_agg(DISTINCT line_number::text, ', ') AS lines
    FROM line_classes
    WHERE specificity = 1 AND auth_method = 'ldap'
    GROUP BY oid
    HAVING count(DISTINCT line_class) > 1
),
roles AS (
    SELECT
        r.oid,
        r.rolname,
        r.rolcanlogin,
        r.rolvaliduntil,
        shobj_description(r.oid, 'pg_authid')               AS role_comment,
        u.account_status,                                    -- EPAS: OPEN, LOCKED, EXPIRED, EXPIRED & LOCKED, ...
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
        cl.line_number                                       AS hba_line,
        coalesce(cl.line_class, 'LOCAL')                     AS line_class,
        c.lines                                              AS conflict_lines,
        ad.first_name,
        ad.last_name,
        ad.owner                                             AS ad_owner,
        ad.cost_centre                                       AS ad_cost_centre
    FROM pg_roles r
    LEFT JOIN sys.dba_users u ON upper(u.username) = upper(r.rolname)   -- sys. prefix: independent of search_path
    LEFT JOIN chosen_line cl  ON cl.oid = r.oid
    LEFT JOIN conflicts   c   ON c.oid  = r.oid
    LEFT JOIN ad_users    ad  ON ad.login = lower(r.rolname)
)
SELECT
    r.oid,
    r.rolname,
    r.rolcanlogin,
    r.role_comment,
    r.created,
    r.is_privileged,
    r.hba_line,
    r.line_class,
    (r.line_class = 'NONPERSON')                             AS is_npid,
    CASE
        WHEN NOT r.rolcanlogin THEN NULL
        WHEN r.conflict_lines IS NOT NULL THEN
            'login ' || r.rolname || ': pg_hba.conf lines ' || r.conflict_lines || ' point to different OUs'
        WHEN r.line_class = 'SIMPLE_BIND' THEN
            'login ' || r.rolname || ': pg_hba.conf line ' || r.hba_line || ' uses simple bind (no ldapbasedn), not supported'
        WHEN r.line_class = 'UNKNOWN_OU' THEN
            'login ' || r.rolname || ': pg_hba.conf line ' || r.hba_line || ' has neither OU='
            || :'person_ou' || ' nor OU=' || :'nonperson_ou' || ' in ldapbasedn'
    END                                                      AS class_error,
    -- Classification (login accounts only; NULL for roles that cannot log in).
    -- Confirm exact spelling against the ID types definition document.
    CASE WHEN NOT r.rolcanlogin            THEN NULL
         WHEN r.line_class = 'NONPERSON'   THEN 'Non-Personal ID'
         WHEN r.line_class = 'PERSON'      THEN 'Personal ID'
         ELSE                                   'Local DB Account'
    END                                                      AS account_type,
    CASE WHEN NOT r.rolcanlogin            THEN NULL
         WHEN r.line_class = 'NONPERSON'   THEN 'Application Connection'
         WHEN r.line_class = 'PERSON'      THEN 'Primary'
         ELSE                                   'Local Authentication'
    END                                                      AS account_subtype,
    CASE WHEN NOT r.rolcanlogin            THEN NULL
         WHEN r.line_class = 'NONPERSON'   THEN 'AD service account ' || r.rolname
         WHEN r.line_class = 'PERSON'      THEN 'Personal database account (AD/LDAP)'
         ELSE                                   'Local database account ' || r.rolname
    END                                                      AS default_description,
    CASE WHEN r.account_status ILIKE '%LOCKED%'                             THEN 'Locked'
         WHEN r.account_status ILIKE 'EXPIRED%' OR r.rolvaliduntil < now()  THEN 'Inactive'
         ELSE                                                                    'Active'
    END                                                      AS status,
    coalesce(r.account_status ILIKE '%LOCKED%', false)       AS is_locked,
    CASE WHEN r.account_status ILIKE '%LOCKED%'  THEN r.lock_date
         WHEN r.account_status ILIKE 'EXPIRED%'  THEN r.expiry_date
         WHEN r.rolvaliduntil < now()            THEN r.rolvaliduntil
    END                                                      AS disabled_at,
    s.source_code,
    s.source_code || ':'                                     AS id_prefix,
    r.first_name,
    r.last_name,
    r.ad_owner,
    r.ad_cost_centre
FROM roles r
CROSS JOIN settings s;
