-- Applied first by scripts/apply_views.sh, inside the same transaction as the CREATE files.
-- Dropping and recreating (instead of CREATE OR REPLACE) lets a view's columns be renamed,
-- removed or reordered. CASCADE also drops the feed views that depend on the base view.
-- Because everything runs in one transaction, other sessions never see the views missing.

DROP VIEW IF EXISTS sailpoint.v_role_base CASCADE;

-- Tables the base view reads. Created here if they do not exist yet.

-- Single-database mode: AD non-person IDs, filled by scripts/ad_npid_sync.sh.
CREATE TABLE IF NOT EXISTS sailpoint.ad_npids (
    rolname   text PRIMARY KEY,
    synced_at timestamptz NOT NULL DEFAULT now()
);

-- Multi-source mode: AD attributes for this cluster's logins, filled each run by
-- scripts/central/collect_all.sh. Empty in single-database mode.
CREATE TABLE IF NOT EXISTS sailpoint.ad_users (
    rolname     text PRIMARY KEY,         -- lower-case login = AD sAMAccountName
    is_npid     boolean NOT NULL,         -- TRUE = AD non-person (service) account
    first_name  text,
    last_name   text,
    owner       text,                     -- manager's name, used as primaryOwner for NPIDs
    cost_centre text,                     -- used as costCentre for NPIDs
    synced_at   timestamptz NOT NULL DEFAULT now()
);

-- Multi-source mode: this cluster's source code (e.g. PRD01), written each run by
-- collect_all.sh. Empty in single-database mode, which means "no prefix".
CREATE TABLE IF NOT EXISTS sailpoint.feed_settings (
    setting text PRIMARY KEY,
    value   text NOT NULL
);
