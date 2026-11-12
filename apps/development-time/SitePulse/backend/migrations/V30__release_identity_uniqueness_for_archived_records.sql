-- Archived tenants and people retain audit history without reserving login/contact identifiers.
ALTER TABLE persons ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

-- Retire credentials and contact identities that already belong to deleted sites.
UPDATE users u
SET is_active = FALSE,
    auth_version = auth_version + 1
FROM sites s
WHERE u.site_id = s.id
  AND s.deleted_at IS NOT NULL
  AND u.is_active;

UPDATE persons p
SET deleted_at = s.deleted_at
FROM sites s
WHERE p.site_id = s.id
  AND s.deleted_at IS NOT NULL
  AND p.deleted_at IS NULL;

UPDATE auth_sessions session
SET revoked_at = COALESCE(session.revoked_at, now())
FROM users u
JOIN sites s ON s.id = u.site_id
WHERE session.user_id = u.id
  AND s.deleted_at IS NOT NULL
  AND session.revoked_at IS NULL;

UPDATE account_activations activation
SET used_at = COALESCE(activation.used_at, now())
FROM users u
JOIN sites s ON s.id = u.site_id
WHERE activation.user_id = u.id
  AND s.deleted_at IS NOT NULL
  AND activation.used_at IS NULL;

-- Unit deletion keeps its person and financial history. Archive a person only when
-- every current unit and occupancy association is gone, so the identity can be reused.
UPDATE persons p
SET deleted_at = now()
WHERE p.deleted_at IS NULL
  AND (
      EXISTS (
          SELECT 1
          FROM unit_occupancies o
          JOIN units u ON u.id = o.unit_id
          WHERE o.person_id = p.id AND u.deleted_at IS NOT NULL
      )
      OR EXISTS (
          SELECT 1
          FROM unit_ownerships o
          JOIN units u ON u.id = o.unit_id
          WHERE o.person_id = p.id AND u.deleted_at IS NOT NULL
      )
      OR EXISTS (
          SELECT 1
          FROM occupancy_members m
          JOIN unit_occupancies o ON o.id = m.occupancy_id
          JOIN units u ON u.id = o.unit_id
          WHERE m.person_id = p.id AND u.deleted_at IS NOT NULL
      )
  )
  AND NOT EXISTS (
      SELECT 1 FROM units u
      WHERE u.deleted_at IS NULL
        AND (u.owner_person_id = p.id OR u.tenant_person_id = p.id)
  )
  AND NOT EXISTS (
      SELECT 1
      FROM unit_occupancies o
      JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
      WHERE o.person_id = p.id AND o.is_active AND o.end_date IS NULL
  )
  AND NOT EXISTS (
      SELECT 1
      FROM occupancy_members m
      JOIN unit_occupancies o ON o.id = m.occupancy_id AND o.is_active AND o.end_date IS NULL
      JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
      WHERE m.person_id = p.id
  );

UPDATE users u
SET is_active = FALSE,
    auth_version = auth_version + 1
WHERE u.is_active
  AND u.person_id IN (SELECT p.id FROM persons p WHERE p.deleted_at IS NOT NULL);

UPDATE auth_sessions session
SET revoked_at = COALESCE(session.revoked_at, now())
WHERE session.revoked_at IS NULL
  AND session.user_id IN (SELECT u.id FROM users u WHERE NOT u.is_active);

UPDATE account_activations activation
SET used_at = COALESCE(activation.used_at, now())
WHERE activation.used_at IS NULL
  AND activation.user_id IN (SELECT u.id FROM users u WHERE NOT u.is_active);

-- Login addresses and Google subjects are reserved only by active accounts.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_email_key;
DROP INDEX IF EXISTS uq_users_email_lower;
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_active_email_lower
    ON users (LOWER(email)) WHERE is_active;

DROP INDEX IF EXISTS uq_user_google_sub;
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_active_google_sub
    ON users (google_sub) WHERE is_active AND google_sub IS NOT NULL;

-- Archived people remain available to historical financial rows but no longer
-- prevent a replacement resident record from using the same contact/identity data.
DROP INDEX IF EXISTS uq_persons_site_email;
CREATE UNIQUE INDEX IF NOT EXISTS uq_persons_site_email
    ON persons (site_id, LOWER(email))
    WHERE email IS NOT NULL AND deleted_at IS NULL;

DROP INDEX IF EXISTS uq_persons_site_national_id_hash;
CREATE UNIQUE INDEX IF NOT EXISTS uq_persons_site_national_id_hash
    ON persons (site_id, national_id_hash)
    WHERE national_id_hash IS NOT NULL AND deleted_at IS NULL;

-- Archived people are not active directory entries.
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
) member ON true
WHERE p.deleted_at IS NULL;

COMMENT ON COLUMN persons.deleted_at IS
    'Soft deletion time. Historical relations are retained while active contact identifiers may be reused.';
