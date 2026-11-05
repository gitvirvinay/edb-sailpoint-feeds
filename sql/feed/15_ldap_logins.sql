-- ldap_logins: the AD settings that apply to each AD login of this cluster, taken from its
-- pg_hba.conf line, so every login is looked up in the AD server and branch Postgres uses
-- to authenticate it. TEMPORARY view. Used by collect_all.sh in its first pass.
--
-- Contains ldapbindpasswd: collect_all.sh writes this output only to a private (0700)
-- temporary folder, never to a log, and deletes it at the end of the run.

CREATE TEMP VIEW ldap_logins AS
SELECT
    lower(b.rolname)                                             AS login,
    b.hba_line,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapserver=%')          AS server,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapport=%')            AS port,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapscheme=%')          AS scheme,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldaptls=%')             AS tls,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapbasedn=%')          AS basedn,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapbinddn=%')          AS binddn,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapbindpasswd=%')      AS bindpasswd,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapsearchattribute=%') AS searchattribute,
    max(substr(o, strpos(o, '=') + 1)) FILTER (WHERE o LIKE 'ldapsearchfilter=%')    AS searchfilter
FROM role_base b
JOIN pg_hba_file_rules h ON h.line_number = b.hba_line
LEFT JOIN LATERAL unnest(coalesce(h.options, '{}'::text[])) o ON true
WHERE b.line_class IN ('PERSON', 'NONPERSON')
GROUP BY b.rolname, b.hba_line;
