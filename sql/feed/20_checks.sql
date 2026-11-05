-- Checks run before anything is extracted. Any failure stops this cluster, and so the
-- whole run publishes nothing (runs are independent: no fallback to earlier data).

DO $$ DECLARE bad text; BEGIN
    -- pg_hba.conf problems found while classifying logins (see 10_base.sql).
    SELECT string_agg(class_error, '; ') INTO bad
    FROM (SELECT class_error FROM role_base
          WHERE class_error IS NOT NULL ORDER BY 1 LIMIT 5) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION '%', bad;
    END IF;

    -- SailPoint "id" is limited to 32 characters (prefix included).
    SELECT string_agg(id, ', ') INTO bad
    FROM (SELECT id_prefix || rolname AS id FROM role_base
          WHERE length(id_prefix || rolname) > 32 ORDER BY 1 LIMIT 5) x;
    IF bad IS NOT NULL THEN
        RAISE EXCEPTION 'IDs longer than 32 characters: % (shorten the source code or the role name)', bad;
    END IF;
END $$;
