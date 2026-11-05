-- Applied first by scripts/apply_views.sh, inside the same transaction as the CREATE files.
-- Dropping and recreating (instead of CREATE OR REPLACE) lets a view's columns be renamed,
-- removed or reordered. CASCADE also drops the feed views that depend on the base view.
-- Because everything runs in one transaction, other sessions never see the views missing.

DROP VIEW IF EXISTS sailpoint.v_role_base CASCADE;

-- The base view reads this table; create it if ad_npid_sync.sh has not run yet.
CREATE TABLE IF NOT EXISTS sailpoint.ad_npids (
    rolname   text PRIMARY KEY,
    synced_at timestamptz NOT NULL DEFAULT now()
);
