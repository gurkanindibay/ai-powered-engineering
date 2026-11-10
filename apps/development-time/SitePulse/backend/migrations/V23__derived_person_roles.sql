-- V23: a person's role comes from what they hold now (person module F6).
--
-- `persons.person_type` stored one role per person, while the same person can own
-- one unit and rent another, or move from tenant to owner. The view derives the
-- role from active ownership and occupancy; the stored value is only the fallback
-- for people without units (site managers, platform admins).

CREATE OR REPLACE VIEW v_person_roles AS
SELECT
    p.id AS person_id,
    p.site_id,
    COALESCE(owned.units, 0) AS owned_units,
    COALESCE(occupied.units, 0) AS occupied_units,
    COALESCE(member.units, 0) AS member_units,
    CASE
        WHEN COALESCE(owned.units, 0) > 0 THEN 'HOME_OWNER'
        WHEN COALESCE(occupied.units, 0) + COALESCE(member.units, 0) > 0 THEN 'HOME_RESIDENT'
        ELSE p.person_type
    END AS derived_role
FROM persons p
LEFT JOIN LATERAL (
    SELECT count(DISTINCT u.id) AS units FROM units u
    WHERE u.deleted_at IS NULL AND (u.owner_person_id = p.id OR EXISTS (
        SELECT 1 FROM unit_ownerships o WHERE o.unit_id = u.id AND o.person_id = p.id AND o.is_active))
) owned ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT o.unit_id) AS units FROM unit_occupancies o
    JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
    WHERE o.person_id = p.id AND o.is_active AND o.end_date IS NULL
) occupied ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT o.unit_id) AS units FROM occupancy_members m
    JOIN unit_occupancies o ON o.id = m.occupancy_id AND o.is_active AND o.end_date IS NULL
    JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
    WHERE m.person_id = p.id
) member ON true;

COMMENT ON COLUMN persons.person_type IS
    'Legacy: the role recorded at creation. Read the current role from v_person_roles.derived_role.';
