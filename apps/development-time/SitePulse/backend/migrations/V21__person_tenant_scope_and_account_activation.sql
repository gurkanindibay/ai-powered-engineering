-- V21: Person tenant scope, login-email credential invalidation and account activation.
--
-- S1  `persons` was a global table matched by email, so a manager of one site could
--     link (and then edit) a person who lives in another site. Every person now
--     belongs to exactly one site; a person referenced from several sites is split
--     into one row per site and that site's references are repointed.
-- S5  Changing a login email now invalidates the user's sessions.
-- S2/S3 Accounts created by a site manager are activated by the person through a
--     single-use token; only its SHA-256 hash is stored.
-- S11 Person changes are written to audit_events like the other domain tables.

ALTER TABLE persons ADD COLUMN IF NOT EXISTS site_id BIGINT;
SELECT sp_set_fk('persons', 'site_id', 'sites', 'fk_persons_site', 'RESTRICT');
CREATE INDEX IF NOT EXISTS idx_persons_site ON persons (site_id);

-- Global identity constraints are replaced by per-site ones below.
ALTER TABLE persons DROP CONSTRAINT IF EXISTS uq_persons_email;
DROP INDEX IF EXISTS uq_persons_email_lower;
ALTER TABLE persons DROP CONSTRAINT IF EXISTS persons_national_id_key;
DROP INDEX IF EXISTS uq_persons_national_id_hash;

-- Every site in which a person is referenced.
DROP TABLE IF EXISTS pg_temp.person_site_usage, pg_temp.person_home_site;
CREATE TEMP TABLE person_site_usage AS
SELECT DISTINCT person_id, site_id FROM (
    SELECT person_id, site_id FROM users WHERE person_id IS NOT NULL
    UNION ALL SELECT owner_person_id, site_id FROM units WHERE owner_person_id IS NOT NULL
    UNION ALL SELECT tenant_person_id, site_id FROM units WHERE tenant_person_id IS NOT NULL
    UNION ALL SELECT o.person_id, u.site_id FROM unit_occupancies o JOIN units u ON u.id = o.unit_id
    UNION ALL SELECT o.person_id, u.site_id FROM unit_ownerships o JOIN units u ON u.id = o.unit_id
    UNION ALL SELECT m.person_id, u.site_id FROM occupancy_members m
        JOIN unit_occupancies o ON o.id = m.occupancy_id JOIN units u ON u.id = o.unit_id
        WHERE m.person_id IS NOT NULL
    UNION ALL SELECT d.liable_person_id, u.site_id FROM dues_liabilities d JOIN units u ON u.id = d.unit_id
        WHERE d.liable_person_id IS NOT NULL
    UNION ALL SELECT payer_person_id, site_id FROM payment_entries WHERE payer_person_id IS NOT NULL
    UNION ALL SELECT payer_person_id, site_id FROM payment_receipts WHERE payer_person_id IS NOT NULL
    UNION ALL SELECT on_behalf_of_person_id, site_id FROM payment_receipts WHERE on_behalf_of_person_id IS NOT NULL
) usage
WHERE person_id IS NOT NULL AND site_id IS NOT NULL;

-- A person's home site: the site of their login account, else the lowest site id.
CREATE TEMP TABLE person_home_site AS
SELECT p.person_id,
       COALESCE((SELECT min(site_id) FROM users u WHERE u.person_id = p.person_id AND u.site_id IS NOT NULL),
                min(p.site_id)) AS site_id
FROM person_site_usage p
GROUP BY p.person_id;

UPDATE persons SET site_id = h.site_id FROM person_home_site h WHERE persons.id = h.person_id;

-- Split: one copy per additional site, with that site's references repointed.
-- The payment ledger guard forbids changing a set payer; this one-off repair is
-- the only writer allowed to do it, so the guards are paused inside this migration.
ALTER TABLE payment_entries DISABLE TRIGGER trg_payment_entries_guard;
ALTER TABLE payment_receipts DISABLE TRIGGER trg_payment_receipts_append_only;
DO $$
DECLARE
    pair RECORD;
    copy_id BIGINT;
BEGIN
    FOR pair IN
        SELECT u.person_id, u.site_id
        FROM person_site_usage u JOIN person_home_site h ON h.person_id = u.person_id
        WHERE u.site_id <> h.site_id
        ORDER BY u.person_id, u.site_id
    LOOP
        INSERT INTO persons (full_name, phone, email, person_type, national_id_hash, national_id_masked, site_id)
        SELECT full_name, phone, email, person_type, national_id_hash, national_id_masked, pair.site_id
        FROM persons WHERE id = pair.person_id
        RETURNING id INTO copy_id;

        UPDATE users SET person_id = copy_id WHERE person_id = pair.person_id AND site_id = pair.site_id;
        UPDATE units SET owner_person_id = copy_id WHERE owner_person_id = pair.person_id AND site_id = pair.site_id;
        UPDATE units SET tenant_person_id = copy_id WHERE tenant_person_id = pair.person_id AND site_id = pair.site_id;
        UPDATE unit_occupancies o SET person_id = copy_id FROM units u
            WHERE u.id = o.unit_id AND o.person_id = pair.person_id AND u.site_id = pair.site_id;
        UPDATE unit_ownerships o SET person_id = copy_id FROM units u
            WHERE u.id = o.unit_id AND o.person_id = pair.person_id AND u.site_id = pair.site_id;
        UPDATE occupancy_members m SET person_id = copy_id FROM unit_occupancies o, units u
            WHERE o.id = m.occupancy_id AND u.id = o.unit_id AND m.person_id = pair.person_id AND u.site_id = pair.site_id;
        UPDATE dues_liabilities d SET liable_person_id = copy_id FROM units u
            WHERE u.id = d.unit_id AND d.liable_person_id = pair.person_id AND u.site_id = pair.site_id;
        UPDATE payment_entries SET payer_person_id = copy_id WHERE payer_person_id = pair.person_id AND site_id = pair.site_id;
        UPDATE payment_receipts SET payer_person_id = copy_id WHERE payer_person_id = pair.person_id AND site_id = pair.site_id;
        UPDATE payment_receipts SET on_behalf_of_person_id = copy_id WHERE on_behalf_of_person_id = pair.person_id AND site_id = pair.site_id;
    END LOOP;
END $$;
ALTER TABLE payment_entries ENABLE TRIGGER trg_payment_entries_guard;
ALTER TABLE payment_receipts ENABLE TRIGGER trg_payment_receipts_append_only;
DROP TABLE pg_temp.person_site_usage, pg_temp.person_home_site;

-- Contact email and national id are unique inside a site, not across the platform.
CREATE UNIQUE INDEX IF NOT EXISTS uq_persons_site_email
    ON persons (site_id, lower(email)) WHERE email IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_persons_site_national_id_hash
    ON persons (site_id, national_id_hash) WHERE national_id_hash IS NOT NULL;

-- A person may only be referenced from their own site. A legacy insert without a
-- site is bound to the first site that references it.
CREATE OR REPLACE FUNCTION sp_bind_person_site(p_person BIGINT, p_site BIGINT) RETURNS void AS $$
DECLARE
    current_site BIGINT;
BEGIN
    IF p_person IS NULL OR p_site IS NULL THEN
        RETURN;
    END IF;
    SELECT site_id INTO current_site FROM persons WHERE id = p_person FOR UPDATE;
    IF NOT FOUND THEN
        RETURN; -- the foreign key reports a missing person
    END IF;
    IF current_site IS NULL THEN
        UPDATE persons SET site_id = p_site WHERE id = p_person;
    ELSIF current_site <> p_site THEN
        RAISE EXCEPTION 'Person % belongs to another site', p_person USING ERRCODE = '42501';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sp_enforce_person_site() RETURNS trigger AS $$
DECLARE
    unit_site BIGINT;
BEGIN
    IF TG_TABLE_NAME = 'users' THEN
        PERFORM sp_bind_person_site(NEW.person_id, NEW.site_id);
    ELSIF TG_TABLE_NAME = 'units' THEN
        PERFORM sp_bind_person_site(NEW.owner_person_id, NEW.site_id);
        PERFORM sp_bind_person_site(NEW.tenant_person_id, NEW.site_id);
    ELSIF TG_TABLE_NAME IN ('unit_occupancies', 'unit_ownerships') THEN
        SELECT site_id INTO unit_site FROM units WHERE id = NEW.unit_id;
        PERFORM sp_bind_person_site(NEW.person_id, unit_site);
    ELSIF TG_TABLE_NAME = 'occupancy_members' THEN
        SELECT u.site_id INTO unit_site FROM unit_occupancies o JOIN units u ON u.id = o.unit_id
        WHERE o.id = NEW.occupancy_id;
        PERFORM sp_bind_person_site(NEW.person_id, unit_site);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_person_site_users ON users;
CREATE TRIGGER trg_person_site_users BEFORE INSERT OR UPDATE OF person_id, site_id ON users
    FOR EACH ROW EXECUTE FUNCTION sp_enforce_person_site();
DROP TRIGGER IF EXISTS trg_person_site_units ON units;
CREATE TRIGGER trg_person_site_units BEFORE INSERT OR UPDATE OF owner_person_id, tenant_person_id, site_id ON units
    FOR EACH ROW EXECUTE FUNCTION sp_enforce_person_site();
DROP TRIGGER IF EXISTS trg_person_site_occupancies ON unit_occupancies;
CREATE TRIGGER trg_person_site_occupancies BEFORE INSERT OR UPDATE OF person_id, unit_id ON unit_occupancies
    FOR EACH ROW EXECUTE FUNCTION sp_enforce_person_site();
DROP TRIGGER IF EXISTS trg_person_site_ownerships ON unit_ownerships;
CREATE TRIGGER trg_person_site_ownerships BEFORE INSERT OR UPDATE OF person_id, unit_id ON unit_ownerships
    FOR EACH ROW EXECUTE FUNCTION sp_enforce_person_site();
DROP TRIGGER IF EXISTS trg_person_site_members ON occupancy_members;
CREATE TRIGGER trg_person_site_members BEFORE INSERT OR UPDATE OF person_id, occupancy_id ON occupancy_members
    FOR EACH ROW EXECUTE FUNCTION sp_enforce_person_site();

-- Person edits are audited (before/after) and tenant-checked by the shared trigger.
DROP TRIGGER IF EXISTS audit_domain_change ON persons;
CREATE TRIGGER audit_domain_change AFTER INSERT OR UPDATE OR DELETE ON persons
    FOR EACH ROW EXECUTE FUNCTION sp_audit_domain_change();

-- S5: a login email change invalidates every session of that user.
CREATE OR REPLACE FUNCTION sp_invalidate_user_credentials() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.password_hash, NEW.role, NEW.site_id, NEW.is_active, NEW.google_sub, lower(NEW.email))
        IS DISTINCT FROM (OLD.password_hash, OLD.role, OLD.site_id, OLD.is_active, OLD.google_sub, lower(OLD.email)) THEN
        NEW.auth_version := OLD.auth_version + 1;
    END IF;
    RETURN NEW;
END $$;

-- S2/S3: single-use activation and email-confirmation tokens.
CREATE TABLE IF NOT EXISTS account_activations (
    token_hash  CHAR(64) PRIMARY KEY,
    user_id     BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    site_id     BIGINT REFERENCES sites(id) ON DELETE CASCADE,
    purpose     VARCHAR(20) NOT NULL CHECK (purpose IN ('ACTIVATE', 'EMAIL_CHANGE')),
    new_email   VARCHAR(120),
    expires_at  TIMESTAMPTZ NOT NULL,
    used_at     TIMESTAMPTZ,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_activation_email CHECK ((purpose = 'EMAIL_CHANGE') = (new_email IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_account_activations_user ON account_activations (user_id, purpose);
DROP TRIGGER IF EXISTS audit_domain_change ON account_activations;
CREATE TRIGGER audit_domain_change AFTER INSERT OR UPDATE OR DELETE ON account_activations
    FOR EACH ROW EXECUTE FUNCTION sp_audit_domain_change();
