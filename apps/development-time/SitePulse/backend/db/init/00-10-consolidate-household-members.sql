-- 00-10: Consolidate Household Members into occupancy_members (English Schema Standard)
-- `unit_members` duplicated `occupancy_members` and carried a fake `resident_id`
-- (VARCHAR, no FK, holding a users.id, a synthetic 'usr-res-<uuid>', or nothing).
-- occupancy_members is the canonical table; identity is a real FK.

-- 1. Real identity links
ALTER TABLE occupancy_members ADD COLUMN IF NOT EXISTS resident_user_id BIGINT REFERENCES users(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_occupancy_members_user ON occupancy_members (resident_user_id);

-- A person may appear only once per occupancy session
CREATE UNIQUE INDEX IF NOT EXISTS uq_occupancy_member_person
    ON occupancy_members (occupancy_id, person_id) WHERE person_id IS NOT NULL;

-- 2. Migrate any remaining unit_members rows, resolving the unit's active occupancy.
DO $$
BEGIN
    IF to_regclass('public.unit_members') IS NOT NULL THEN
        INSERT INTO occupancy_members (occupancy_id, person_id, resident_user_id, full_name, relationship, phone, email, is_emergency_contact, created_at)
        SELECT
            uo.id,
            COALESCE(um_person.id, p.id),
            CASE WHEN um.resident_id ~ '^[0-9]+$' THEN um.resident_id::BIGINT END,
            um.full_name,
            um.relationship,
            um.phone,
            um.email,
            false,
            um.created_at
        FROM unit_members um
        JOIN units u ON u.id = um.unit_id
        JOIN unit_occupancies uo ON uo.unit_id = u.id AND uo.is_active = true
        LEFT JOIN persons um_person ON um_person.id = NULLIF(regexp_replace(um.resident_id, '\D', '', 'g'), '')::BIGINT
        LEFT JOIN persons p ON LOWER(p.email) = LOWER(um.email)
        WHERE NOT EXISTS (
            SELECT 1 FROM occupancy_members om
            WHERE om.occupancy_id = uo.id AND om.full_name = um.full_name
        );

        -- 3. Drop the redundant table and its synchronizer trigger
        DROP TRIGGER IF EXISTS trg_sync_unit_members ON unit_members;
        DROP FUNCTION IF EXISTS fn_sync_unit_member_to_occupancy();
        DROP TABLE IF EXISTS unit_members CASCADE;
    END IF;
END $$;

-- 4. Orphaned occupancy_members cleanup: rows whose person was deleted keep full_name only.
--    (person_id is already ON DELETE SET NULL.)
CREATE INDEX IF NOT EXISTS idx_occupancy_members_full_name ON occupancy_members (occupancy_id, full_name);
