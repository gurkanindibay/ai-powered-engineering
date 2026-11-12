-- A deleted tenant keeps its row for audit, but its public slug may be reused.
ALTER TABLE sites DROP CONSTRAINT IF EXISTS sites_slug_key;

CREATE UNIQUE INDEX IF NOT EXISTS uq_sites_active_slug
    ON sites (slug)
    WHERE deleted_at IS NULL;
