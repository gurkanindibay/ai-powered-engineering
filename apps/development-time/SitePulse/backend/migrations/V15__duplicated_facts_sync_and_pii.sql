-- V15: Sync rules for duplicated facts (M1) and no clear-text national ids (M6).

-- ---------------------------------------------------------------------------
-- M1: units.owner_person_id / tenant_person_id are derived from the history
-- tables (unit_ownerships, unit_occupancies), which are the source of truth.
-- Any change to the history recomputes the unit columns, so the two copies
-- cannot disagree. Other duplicated pairs are reported by v_duplicated_fact_drift.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_sync_unit_owner() RETURNS trigger AS $$
DECLARE target BIGINT := COALESCE(NEW.unit_id, OLD.unit_id);
BEGIN
    UPDATE units u
    SET owner_person_id = (
        SELECT o.person_id FROM unit_ownerships o
        WHERE o.unit_id = target AND o.is_active
        ORDER BY o.share_percentage DESC, o.start_date DESC, o.id DESC LIMIT 1)
    WHERE u.id = target
      AND EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = target);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_unit_owner ON unit_ownerships;
CREATE TRIGGER trg_sync_unit_owner AFTER INSERT OR UPDATE OR DELETE ON unit_ownerships
    FOR EACH ROW EXECUTE FUNCTION sp_sync_unit_owner();

CREATE OR REPLACE FUNCTION sp_sync_unit_tenant() RETURNS trigger AS $$
DECLARE target BIGINT := COALESCE(NEW.unit_id, OLD.unit_id);
BEGIN
    UPDATE units u
    SET tenant_person_id = (
        SELECT oc.person_id FROM unit_occupancies oc
        WHERE oc.unit_id = target AND oc.is_active AND oc.occupancy_type = 'TENANT'
        ORDER BY oc.start_date DESC, oc.id DESC LIMIT 1)
    WHERE u.id = target;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_unit_tenant ON unit_occupancies;
CREATE TRIGGER trg_sync_unit_tenant AFTER INSERT OR UPDATE OR DELETE ON unit_occupancies
    FOR EACH ROW EXECUTE FUNCTION sp_sync_unit_tenant();

CREATE OR REPLACE VIEW v_duplicated_fact_drift AS
SELECT 'units.owner_person_id' AS fact, u.id::text AS subject,
       u.owner_person_id::text AS legacy_value, o.person_id::text AS source_value
FROM units u
JOIN LATERAL (SELECT person_id FROM unit_ownerships x WHERE x.unit_id = u.id AND x.is_active
              ORDER BY share_percentage DESC, start_date DESC, id DESC LIMIT 1) o ON TRUE
WHERE u.owner_person_id IS DISTINCT FROM o.person_id
UNION ALL
SELECT 'users.site_id/role', us.id::text, us.site_id::text || '/' || us.role, r.site_id::text || '/' || r.role
FROM users us JOIN user_site_roles r ON r.user_id = us.id
WHERE us.site_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM user_site_roles r2 WHERE r2.user_id = us.id AND r2.site_id = us.site_id AND r2.role = us.role)
UNION ALL
SELECT 'dues_liabilities.period/dues_period_id', d.id::text, d.period, p.period_name
FROM dues_liabilities d JOIN dues_periods p ON p.id = d.dues_period_id
WHERE d.period <> p.period_name
UNION ALL
SELECT 'payment_receipts.allocated_*/payment_allocations', r.id::text,
       (r.allocated_principal + r.allocated_penalty)::text, COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0)::text
FROM payment_receipts r
JOIN payment_entries e ON e.receipt_id = r.id
LEFT JOIN payment_allocations pa ON pa.payment_entry_id = e.id
GROUP BY r.id
HAVING (r.allocated_principal + r.allocated_penalty) <> COALESCE(SUM(pa.principal_amount + pa.penalty_amount), 0);

-- ---------------------------------------------------------------------------
-- M6: the T.C. Kimlik No is never stored in clear text. A trigger replaces it
-- with an HMAC-SHA256 digest (keyed with a per-database secret, for uniqueness
-- and lookups) and a masked form for display, whoever writes the row.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS pii_settings (
    id         BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (id),
    hmac_key   BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO pii_settings (hmac_key) VALUES (gen_random_bytes(32)) ON CONFLICT (id) DO NOTHING;
REVOKE ALL ON pii_settings FROM PUBLIC;

ALTER TABLE persons ADD COLUMN IF NOT EXISTS national_id_hash VARCHAR(64);
ALTER TABLE persons ADD COLUMN IF NOT EXISTS national_id_masked VARCHAR(11);

CREATE OR REPLACE FUNCTION sp_protect_national_id() RETURNS trigger AS $$
BEGIN
    IF NEW.national_id IS NOT NULL AND NEW.national_id <> '' THEN
        NEW.national_id_hash := encode(hmac(convert_to(NEW.national_id, 'UTF8'), (SELECT hmac_key FROM pii_settings), 'sha256'), 'hex');
        NEW.national_id_masked := repeat('*', GREATEST(length(NEW.national_id) - 4, 0)) || right(NEW.national_id, 4);
    END IF;
    NEW.national_id := NULL;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_protect_national_id ON persons;
CREATE TRIGGER trg_protect_national_id BEFORE INSERT OR UPDATE OF national_id ON persons
    FOR EACH ROW EXECUTE FUNCTION sp_protect_national_id();

-- Existing clear-text values are converted by the trigger.
UPDATE persons SET national_id = national_id WHERE national_id IS NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS (SELECT national_id_hash FROM persons WHERE national_id_hash IS NOT NULL GROUP BY 1 HAVING COUNT(*) > 1) THEN
        CREATE UNIQUE INDEX IF NOT EXISTS uq_persons_national_id_hash ON persons (national_id_hash) WHERE national_id_hash IS NOT NULL;
    ELSE
        RAISE WARNING 'uq_persons_national_id_hash not created: duplicate national ids exist';
    END IF;
END $$;
