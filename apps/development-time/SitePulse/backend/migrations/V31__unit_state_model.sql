-- V31: Unit ownership & occupancy state model (EPIC-08 §3, STORY-08-06..10).
--
-- Ownership lives in unit_ownerships and occupancy in unit_occupancies. The
-- unit columns owner_person_id, tenant_person_id (V15) and occupancy_status
-- (here) are projections of those tables. This migration:
--   1. reconciles existing rows once (ownership backfill, owner projection,
--      sessions V27 opened on units recorded as VACANT),
--   2. derives units.occupancy_status from the active occupancy session,
--   3. checks at commit that an active OWNER session belongs to an owner and
--      an active TENANT session does not,
--   4. records every guarded transition in occupancy_transitions,
--   5. reports what still disagrees in v_unit_state_drift.

-- ---------------------------------------------------------------------------
-- Owners of record: active ownership rows; for a unit with no ownership
-- history at all (pre-V7 data, direct seeds) the unit's owner column.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_unit_owner_ids(p_unit BIGINT)
RETURNS TABLE (person_id BIGINT) LANGUAGE sql STABLE AS $$
    SELECT o.person_id FROM unit_ownerships o WHERE o.unit_id = p_unit AND o.is_active
    UNION
    SELECT u.owner_person_id FROM units u
    WHERE u.id = p_unit AND u.owner_person_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM unit_ownerships x WHERE x.unit_id = p_unit);
$$;

-- The occupancy implied by the unit's active session (none: VACANT).
CREATE OR REPLACE FUNCTION sp_unit_occupancy_status(p_unit BIGINT)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT COALESCE((
        SELECT CASE WHEN oc.occupancy_type = 'OWNER' THEN 'OWNER_OCCUPIED' ELSE 'TENANT_OCCUPIED' END
        FROM unit_occupancies oc
        WHERE oc.unit_id = p_unit AND oc.is_active
        ORDER BY oc.start_date DESC, oc.id DESC LIMIT 1), 'VACANT');
$$;

-- ---------------------------------------------------------------------------
-- 1. One-time reconciliation.
-- ---------------------------------------------------------------------------
-- 1a. Units registered with an owner but without an ownership row get one, so
--     the owner on record is in the source-of-truth table.
INSERT INTO unit_ownerships (unit_id, person_id, share_percentage, start_date, is_active)
SELECT u.id, u.owner_person_id, 100.00, COALESCE(u.created_at::date, CURRENT_DATE), TRUE
FROM units u
WHERE u.owner_person_id IS NOT NULL
  AND u.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = u.id AND o.is_active)
ON CONFLICT DO NOTHING;

-- 1b. The owner column follows the active ownership (an owner move-in used to
--     overwrite it without recording a transfer, gap G1).
WITH primary_owner AS (
    SELECT DISTINCT ON (x.unit_id) x.unit_id, x.person_id
    FROM unit_ownerships x
    WHERE x.is_active
    ORDER BY x.unit_id, x.share_percentage DESC, x.start_date DESC, x.id DESC)
UPDATE units u
SET owner_person_id = o.person_id
FROM primary_owner o
WHERE o.unit_id = u.id AND u.owner_person_id IS DISTINCT FROM o.person_id;

-- 1c. V27 opened an owner session on every owned unit without a tenant,
--     including units a move-out had recorded as VACANT. Those sessions never
--     happened: they are closed on their start date without an exit balance.
UPDATE unit_occupancies oc
SET is_active = FALSE,
    end_date = oc.start_date,
    exit_balance = 0.00,
    notes = concat_ws(' • ', NULLIF(oc.notes, ''), 'V31: closed, the unit was recorded as VACANT')
FROM units u
WHERE u.id = oc.unit_id
  AND oc.is_active
  AND oc.occupancy_type = 'OWNER'
  AND u.occupancy_status = 'VACANT';

-- ---------------------------------------------------------------------------
-- 2. occupancy_status is derived (invariant 2). Any write to the column is
--    replaced by the value implied by the sessions, and every session change
--    recomputes it.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_derive_unit_occupancy_status() RETURNS trigger AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.occupancy_status := 'VACANT';
        IF NEW.id IS NOT NULL THEN
            NEW.occupancy_status := sp_unit_occupancy_status(NEW.id);
        END IF;
    ELSE
        NEW.occupancy_status := sp_unit_occupancy_status(NEW.id);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_derive_unit_occupancy_status ON units;
CREATE TRIGGER trg_derive_unit_occupancy_status BEFORE INSERT OR UPDATE OF occupancy_status ON units
    FOR EACH ROW EXECUTE FUNCTION sp_derive_unit_occupancy_status();

CREATE OR REPLACE FUNCTION sp_sync_unit_occupancy_status() RETURNS trigger AS $$
DECLARE target BIGINT := COALESCE(NEW.unit_id, OLD.unit_id);
BEGIN
    UPDATE units u SET occupancy_status = sp_unit_occupancy_status(target)
    WHERE u.id = target AND u.occupancy_status IS DISTINCT FROM sp_unit_occupancy_status(target);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_sync_unit_occupancy_status ON unit_occupancies;
CREATE TRIGGER trg_sync_unit_occupancy_status AFTER INSERT OR UPDATE OR DELETE ON unit_occupancies
    FOR EACH ROW EXECUTE FUNCTION sp_sync_unit_occupancy_status();

-- Existing rows take their derived value now (the BEFORE trigger computes it).
UPDATE units SET occupancy_status = occupancy_status;

-- ---------------------------------------------------------------------------
-- 3. Invariant 3: an active OWNER session belongs to an owner of the unit, and
--    an active TENANT session does not. Checked at commit, so a transition may
--    change ownership and occupancy in either order inside one transaction.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_check_unit_session_owner() RETURNS trigger AS $$
DECLARE
    target BIGINT := COALESCE(NEW.unit_id, OLD.unit_id);
    session RECORD;
    is_owner BOOLEAN;
BEGIN
    FOR session IN
        SELECT oc.person_id, oc.occupancy_type FROM unit_occupancies oc
        WHERE oc.unit_id = target AND oc.is_active
    LOOP
        is_owner := EXISTS (SELECT 1 FROM sp_unit_owner_ids(target) o WHERE o.person_id = session.person_id);
        IF session.occupancy_type = 'OWNER' AND NOT is_owner THEN
            RAISE EXCEPTION 'Owner occupancy of unit % belongs to person %, who is not an owner of the unit',
                target, session.person_id USING ERRCODE = 'check_violation';
        END IF;
        IF session.occupancy_type = 'TENANT' AND is_owner THEN
            RAISE EXCEPTION 'Tenant occupancy of unit % belongs to person %, who is an owner of the unit',
                target, session.person_id USING ERRCODE = 'check_violation';
        END IF;
    END LOOP;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_check_session_owner ON unit_occupancies;
CREATE CONSTRAINT TRIGGER trg_check_session_owner AFTER INSERT OR UPDATE ON unit_occupancies
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW WHEN (NEW.is_active) EXECUTE FUNCTION sp_check_unit_session_owner();

DROP TRIGGER IF EXISTS trg_check_session_owner ON unit_ownerships;
CREATE CONSTRAINT TRIGGER trg_check_session_owner AFTER INSERT OR UPDATE ON unit_ownerships
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION sp_check_unit_session_owner();

-- ---------------------------------------------------------------------------
-- 4. Audit record of every guarded transition (STORY-08-10): who, when, the
--    command, and the state before and after. Append-only.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS occupancy_transitions (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    site_id BIGINT NOT NULL REFERENCES sites(id),
    unit_id BIGINT NOT NULL REFERENCES units(id),
    command VARCHAR(30) NOT NULL,
    from_ownership VARCHAR(10) NOT NULL,
    from_occupancy VARCHAR(20) NOT NULL,
    to_ownership VARCHAR(10) NOT NULL,
    to_occupancy VARCHAR(20) NOT NULL,
    effective_date DATE NOT NULL,
    closed_occupancy_id BIGINT REFERENCES unit_occupancies(id),
    opened_occupancy_id BIGINT REFERENCES unit_occupancies(id),
    actor_id TEXT NOT NULL DEFAULT COALESCE(
        NULLIF(current_setting('sitepulse.audit_context', true), '')::jsonb->>'actor_id', current_user),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_transition_command CHECK (command IN (
        'REGISTER_OWNER', 'TENANT_MOVE_IN', 'OWNER_MOVE_IN', 'MOVE_OUT',
        'REPLACE_TENANT', 'OWNER_RENTS_OUT', 'OWNER_TAKES_BACK', 'TITLE_TRANSFER')),
    CONSTRAINT chk_transition_ownership CHECK (
        from_ownership IN ('UNOWNED', 'OWNED') AND to_ownership IN ('UNOWNED', 'OWNED')),
    CONSTRAINT chk_transition_occupancy CHECK (
        from_occupancy IN ('VACANT', 'OWNER_OCCUPIED', 'TENANT_OCCUPIED')
        AND to_occupancy IN ('VACANT', 'OWNER_OCCUPIED', 'TENANT_OCCUPIED'))
);
CREATE INDEX IF NOT EXISTS idx_occupancy_transitions_unit ON occupancy_transitions (unit_id, created_at);

DROP TRIGGER IF EXISTS trg_occupancy_transitions_append_only ON occupancy_transitions;
CREATE TRIGGER trg_occupancy_transitions_append_only BEFORE UPDATE OR DELETE ON occupancy_transitions
    FOR EACH ROW EXECUTE FUNCTION sp_ledger_append_only();

DROP TRIGGER IF EXISTS audit_domain_change ON occupancy_transitions;
CREATE TRIGGER audit_domain_change AFTER INSERT OR UPDATE OR DELETE ON occupancy_transitions
    FOR EACH ROW EXECUTE FUNCTION sp_audit_domain_change();

SELECT sp_enable_tenant_rls('occupancy_transitions', 'site_id = sp_tenant_site()');

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sitepulse_tenant') THEN
        GRANT SELECT, INSERT ON occupancy_transitions TO sitepulse_tenant;
        GRANT USAGE, SELECT ON SEQUENCE occupancy_transitions_id_seq TO sitepulse_tenant;
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5. What still disagrees with the state model, for an operator to resolve.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_unit_state_drift AS
SELECT u.id AS unit_id, u.site_id, 'OCCUPANCY_STATUS' AS issue,
       u.occupancy_status AS recorded, sp_unit_occupancy_status(u.id) AS expected
FROM units u
WHERE u.deleted_at IS NULL AND u.occupancy_status IS DISTINCT FROM sp_unit_occupancy_status(u.id)
UNION ALL
SELECT oc.unit_id, u.site_id, 'OWNER_SESSION_NOT_OWNER', oc.person_id::text, NULL
FROM unit_occupancies oc JOIN units u ON u.id = oc.unit_id
WHERE oc.is_active AND oc.occupancy_type = 'OWNER'
  AND NOT EXISTS (SELECT 1 FROM sp_unit_owner_ids(oc.unit_id) o WHERE o.person_id = oc.person_id)
UNION ALL
SELECT oc.unit_id, u.site_id, 'TENANT_SESSION_IS_OWNER', oc.person_id::text, NULL
FROM unit_occupancies oc JOIN units u ON u.id = oc.unit_id
WHERE oc.is_active AND oc.occupancy_type = 'TENANT'
  AND EXISTS (SELECT 1 FROM sp_unit_owner_ids(oc.unit_id) o WHERE o.person_id = oc.person_id)
UNION ALL
SELECT oc.unit_id, u.site_id, 'TENANT_WITHOUT_OWNER', oc.person_id::text, NULL
FROM unit_occupancies oc JOIN units u ON u.id = oc.unit_id
WHERE oc.is_active AND oc.occupancy_type = 'TENANT' AND u.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM sp_unit_owner_ids(oc.unit_id))
UNION ALL
SELECT u.id, u.site_id, 'OWNER_PROJECTION', u.owner_person_id::text, o.person_id::text
FROM units u
JOIN LATERAL (SELECT x.person_id FROM unit_ownerships x WHERE x.unit_id = u.id AND x.is_active
              ORDER BY x.share_percentage DESC, x.start_date DESC, x.id DESC LIMIT 1) o ON TRUE
WHERE u.owner_person_id IS DISTINCT FROM o.person_id;
