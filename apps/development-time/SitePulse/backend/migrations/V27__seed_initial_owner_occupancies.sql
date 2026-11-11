-- Owner-occupied seeded units need an active occupancy session before a
-- household member can join through an invitation.
INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date, is_active)
SELECT
    u.id,
    u.owner_person_id,
    'OWNER',
    COALESCE(u.created_at::date, CURRENT_DATE),
    TRUE
FROM units u
WHERE u.deleted_at IS NULL
  AND u.owner_person_id IS NOT NULL
  AND u.tenant_person_id IS NULL
  AND NOT EXISTS (
      SELECT 1
      FROM unit_occupancies current_occupancy
      WHERE current_occupancy.unit_id = u.id
        AND current_occupancy.is_active = TRUE
  )
ON CONFLICT DO NOTHING;
