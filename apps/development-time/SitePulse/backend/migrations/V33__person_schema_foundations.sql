-- Person-card schema foundations. Historical rows are preserved; only constraints
-- whose measured preconditions are satisfied are tightened in this release.

ALTER TABLE persons ADD COLUMN IF NOT EXISTS phone_key VARCHAR(10);
ALTER TABLE persons ADD COLUMN IF NOT EXISTS name_key VARCHAR(120);
ALTER TABLE persons ADD COLUMN IF NOT EXISTS version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE persons ADD COLUMN IF NOT EXISTS merged_into_person_id BIGINT;
ALTER TABLE persons ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP;

ALTER TABLE persons DROP CONSTRAINT IF EXISTS fk_persons_merged_into;
ALTER TABLE persons ADD CONSTRAINT fk_persons_merged_into
    FOREIGN KEY (merged_into_person_id) REFERENCES persons(id) ON DELETE RESTRICT;
ALTER TABLE persons DROP CONSTRAINT IF EXISTS chk_persons_not_merged_into_self;
ALTER TABLE persons ADD CONSTRAINT chk_persons_not_merged_into_self
    CHECK (merged_into_person_id IS NULL OR merged_into_person_id <> id);

CREATE OR REPLACE FUNCTION sp_person_name_key(raw_name TEXT)
RETURNS TEXT
LANGUAGE SQL
IMMUTABLE
STRICT
PARALLEL SAFE
AS $$
    WITH folded AS (
        SELECT regexp_replace(
            translate(translate(lower(raw_name), 'ıişğüöç', 'iisguoc'),
                      U&'\0307\0306\0308\0327', ''),
            '\s+', ' ', 'g'
        ) AS value
    ), words AS (
        SELECT word
        FROM folded,
             unnest(string_to_array(regexp_replace(btrim(value), '\s+', ' ', 'g'), ' ')) AS word
        WHERE word <> ''
    )
    SELECT NULLIF(string_agg(word, ' ' ORDER BY word), '') FROM words
$$;

CREATE OR REPLACE FUNCTION sp_person_search_keys_before_write()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.phone_key := CASE
        WHEN length(regexp_replace(COALESCE(NEW.phone, ''), '[^0-9]', '', 'g')) >= 10
        THEN right(regexp_replace(COALESCE(NEW.phone, ''), '[^0-9]', '', 'g'), 10)
        ELSE NULL
    END;
    NEW.name_key := sp_person_name_key(NEW.full_name);
    NEW.updated_at := CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_person_search_keys_before_write ON persons;
CREATE TRIGGER trg_person_search_keys_before_write
BEFORE INSERT OR UPDATE OF full_name, phone ON persons
FOR EACH ROW EXECUTE FUNCTION sp_person_search_keys_before_write();

UPDATE persons
SET phone_key = CASE
        WHEN length(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g')) >= 10
        THEN right(regexp_replace(COALESCE(phone, ''), '[^0-9]', '', 'g'), 10)
        ELSE NULL
    END,
    name_key = sp_person_name_key(full_name)
WHERE phone_key IS NULL OR name_key IS NULL;

CREATE INDEX IF NOT EXISTS idx_persons_site_phone_key
    ON persons (site_id, phone_key) WHERE phone_key IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_persons_site_name_key_prefix
    ON persons (site_id, name_key text_pattern_ops) WHERE name_key IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_persons_merged_into
    ON persons (merged_into_person_id) WHERE merged_into_person_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_persons_site_id_id
    ON persons (site_id, id);

-- The baseline found no unlinked members or duplicate active logins. Keep the
-- member link nullable during the compatibility release because current writers
-- still accept copied member fields without a person reference. The site
-- constraint is also deferred because two non-admin people lack a site.
CREATE UNIQUE INDEX IF NOT EXISTS uq_users_one_active_login_per_person
    ON users (person_id) WHERE is_active AND person_id IS NOT NULL;

ALTER TABLE units ADD COLUMN IF NOT EXISTS primary_contact_person_id BIGINT;
ALTER TABLE units DROP CONSTRAINT IF EXISTS fk_units_primary_contact_person;
ALTER TABLE units ADD CONSTRAINT fk_units_primary_contact_person
    FOREIGN KEY (site_id, primary_contact_person_id) REFERENCES persons(site_id, id) ON DELETE RESTRICT;

-- Prefer the stable member id; use a name only when it identifies exactly one
-- eligible person on the unit. Ambiguous and unmatched rows remain null for review.
UPDATE units u
SET primary_contact_person_id = member.person_id
FROM occupancy_members member
JOIN unit_occupancies occupancy ON occupancy.id = member.occupancy_id
JOIN persons member_person ON member_person.id = member.person_id
WHERE u.primary_contact_person_id IS NULL
  AND u.primary_responsible_contact IS NOT NULL
  AND NULLIF(u.primary_responsible_contact->>'primary_responsible_member_id', '') ~ '^[0-9]+$'
  AND member.id = (u.primary_responsible_contact->>'primary_responsible_member_id')::BIGINT
  AND occupancy.unit_id = u.id
  AND occupancy.is_active
  AND member_person.site_id = u.site_id;

WITH matching_contacts AS (
    SELECT u.id AS unit_id, min(p.id) AS person_id, count(*) AS candidate_count
    FROM units u
    JOIN persons p ON p.full_name = u.primary_responsible_contact->>'primary_responsible_name'
                  AND p.site_id = u.site_id
    WHERE u.primary_contact_person_id IS NULL
      AND u.primary_responsible_contact IS NOT NULL
      AND u.primary_responsible_contact->>'primary_responsible_member_id' IS NULL
      AND (
          p.id IN (u.owner_person_id, u.tenant_person_id)
          OR EXISTS (SELECT 1 FROM unit_ownerships o
                     WHERE o.unit_id = u.id AND o.person_id = p.id AND o.is_active)
          OR EXISTS (SELECT 1 FROM unit_occupancies o
                     WHERE o.unit_id = u.id AND o.person_id = p.id AND o.is_active AND o.end_date IS NULL)
          OR EXISTS (SELECT 1 FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id
                     WHERE o.unit_id = u.id AND o.is_active AND m.person_id = p.id)
      )
    GROUP BY u.id
)
UPDATE units u
SET primary_contact_person_id = matching_contacts.person_id
FROM matching_contacts
WHERE matching_contacts.unit_id = u.id AND matching_contacts.candidate_count = 1;

CREATE INDEX IF NOT EXISTS idx_units_primary_contact_person
    ON units (site_id, primary_contact_person_id) WHERE primary_contact_person_id IS NOT NULL;

-- The existing role view keeps its original leading columns for compatibility.
CREATE OR REPLACE VIEW v_person_roles WITH (security_invoker = true) AS
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
    END AS derived_role,
    COALESCE(owned.units, 0) > 0 AS is_owner,
    COALESCE(owner_occupant.units, 0) > 0 AS is_owner_occupant,
    COALESCE(tenant.units, 0) > 0 AS is_tenant,
    COALESCE(member.units, 0) > 0 AS is_member,
    COALESCE(primary_contact.units, 0) > 0 AS is_primary_contact,
    CASE WHEN EXISTS (
        SELECT 1 FROM users active_user
        WHERE active_user.person_id = p.id AND active_user.site_id IS NOT DISTINCT FROM p.site_id
          AND active_user.is_active
    ) THEN 'ACTIVE' ELSE 'NONE' END AS login_state
FROM persons p
LEFT JOIN LATERAL (
    SELECT count(DISTINCT u.id) AS units FROM units u
    WHERE u.deleted_at IS NULL AND u.site_id = p.site_id AND (u.owner_person_id = p.id OR EXISTS (
        SELECT 1 FROM unit_ownerships o WHERE o.unit_id = u.id AND o.person_id = p.id AND o.is_active))
) owned ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT o.unit_id) AS units FROM unit_occupancies o
    JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
    WHERE o.person_id = p.id AND u.site_id = p.site_id AND o.is_active AND o.end_date IS NULL
) occupied ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT o.unit_id) AS units FROM unit_occupancies o
    JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
    WHERE o.person_id = p.id AND u.site_id = p.site_id AND o.is_active AND o.end_date IS NULL AND o.occupancy_type = 'OWNER'
) owner_occupant ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT o.unit_id) AS units FROM unit_occupancies o
    JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
    WHERE o.person_id = p.id AND u.site_id = p.site_id AND o.is_active AND o.end_date IS NULL AND o.occupancy_type = 'TENANT'
) tenant ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT o.unit_id) AS units FROM occupancy_members m
    JOIN unit_occupancies o ON o.id = m.occupancy_id AND o.is_active AND o.end_date IS NULL
    JOIN units u ON u.id = o.unit_id AND u.deleted_at IS NULL
    WHERE m.person_id = p.id AND u.site_id = p.site_id
) member ON true
LEFT JOIN LATERAL (
    SELECT count(DISTINCT u.id) AS units FROM units u
    WHERE u.deleted_at IS NULL AND u.site_id = p.site_id AND u.primary_contact_person_id = p.id
) primary_contact ON true
WHERE p.deleted_at IS NULL AND p.merged_into_person_id IS NULL;

CREATE OR REPLACE VIEW v_person_unit_relations WITH (security_invoker = true) AS
SELECT o.person_id, o.unit_id, o.occupancy_type AS relation, o.start_date, o.end_date,
       (o.is_active AND o.end_date IS NULL) AS active,
       u.site_id, COALESCE(b.block_name, '') || ' ' || u.unit_number::TEXT AS unit_label
FROM unit_occupancies o JOIN units u ON u.id = o.unit_id
JOIN persons p ON p.id = o.person_id AND p.site_id = u.site_id
LEFT JOIN blocks b ON b.id = u.block_id
WHERE u.deleted_at IS NULL
UNION ALL
SELECT o.person_id, o.unit_id, 'OWNER' AS relation, o.start_date, o.end_date,
       (o.is_active AND o.end_date IS NULL) AS active,
       u.site_id, COALESCE(b.block_name, '') || ' ' || u.unit_number::TEXT AS unit_label
FROM unit_ownerships o JOIN units u ON u.id = o.unit_id
JOIN persons p ON p.id = o.person_id AND p.site_id = u.site_id
LEFT JOIN blocks b ON b.id = u.block_id
WHERE u.deleted_at IS NULL
UNION ALL
SELECT m.person_id, o.unit_id, 'HOUSEHOLD_MEMBER' AS relation, o.start_date, o.end_date,
       (o.is_active AND o.end_date IS NULL) AS active,
       u.site_id, COALESCE(b.block_name, '') || ' ' || u.unit_number::TEXT AS unit_label
FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id
JOIN units u ON u.id = o.unit_id
JOIN persons p ON p.id = m.person_id AND p.site_id = u.site_id
LEFT JOIN blocks b ON b.id = u.block_id
WHERE m.person_id IS NOT NULL AND u.deleted_at IS NULL;

CREATE OR REPLACE VIEW v_person_card WITH (security_invoker = true) AS
SELECT p.id AS person_id, p.site_id, p.full_name, p.phone, p.email,
       p.national_id_masked, p.version, roles.derived_role,
       roles.is_owner, roles.is_owner_occupant, roles.is_tenant, roles.is_member,
       roles.is_primary_contact, roles.login_state,
       COALESCE(units.unit_count, 0)::INTEGER AS unit_count,
       COALESCE(units.unit_labels, ARRAY[]::TEXT[]) AS unit_labels
FROM persons p
JOIN v_person_roles roles ON roles.person_id = p.id
LEFT JOIN LATERAL (
    SELECT count(DISTINCT relation.unit_id) AS unit_count,
           array_agg(DISTINCT relation.unit_label ORDER BY relation.unit_label) AS unit_labels
    FROM v_person_unit_relations relation
    WHERE relation.person_id = p.id AND relation.active
) units ON true
WHERE p.deleted_at IS NULL AND p.merged_into_person_id IS NULL;

CREATE OR REPLACE VIEW v_unit_directory WITH (security_invoker = true) AS
SELECT u.id AS unit_id, u.site_id, u.block_id, b.block_name, u.unit_number, u.floor,
       u.house_type, u.occupancy_status, occupant.id AS occupant_person_id,
       occupant.full_name AS occupant_name, owners.owner_count,
       owners.person_id AS first_owner_person_id, owners.full_name AS first_owner_name,
       u.primary_contact_person_id, contact.full_name AS primary_contact_name,
       CASE WHEN contact.id IS NULL THEN NULL
            WHEN contact.id = u.owner_person_id OR owners.has_contact THEN 'OWNER'
            WHEN contact.id = u.tenant_person_id OR occupant.id = contact.id THEN 'RESIDENT'
            ELSE 'HOUSEHOLD_MEMBER' END AS primary_contact_role,
       concat_ws(' ', occupant.name_key, owners.owner_keys, members.member_keys,
                 contact.name_key, occupant.phone_key, owners.owner_phone_keys, members.member_phone_keys,
                 contact.phone_key, occupant.email, owners.owner_emails, members.member_emails, contact.email) AS search_keys
FROM units u
JOIN blocks b ON b.id = u.block_id
LEFT JOIN persons occupant ON occupant.id = COALESCE(
    (SELECT o.person_id FROM unit_occupancies o WHERE o.unit_id = u.id AND o.is_active AND o.end_date IS NULL
     ORDER BY o.start_date DESC, o.id DESC LIMIT 1),
     u.tenant_person_id, u.owner_person_id) AND occupant.site_id = u.site_id
LEFT JOIN LATERAL (
    SELECT count(DISTINCT p.id)::INTEGER AS owner_count,
           (array_agg(p.id ORDER BY o.share_percentage DESC NULLS LAST, o.start_date DESC NULLS LAST, p.id))[1] AS person_id,
           (array_agg(p.full_name ORDER BY o.share_percentage DESC NULLS LAST, o.start_date DESC NULLS LAST, p.id))[1] AS full_name,
           string_agg(DISTINCT p.full_name, ' ') AS owner_names,
           string_agg(DISTINCT p.name_key, ' ') AS owner_keys,
           string_agg(DISTINCT p.phone, ' ') AS owner_phones,
           string_agg(DISTINCT p.phone_key, ' ') AS owner_phone_keys,
           string_agg(DISTINCT p.email, ' ') AS owner_emails,
           bool_or(p.id = u.primary_contact_person_id) AS has_contact
    FROM persons p
    LEFT JOIN LATERAL (SELECT ownership.share_percentage, ownership.start_date
                       FROM unit_ownerships ownership
                       WHERE ownership.unit_id = u.id AND ownership.person_id = p.id AND ownership.is_active
                       ORDER BY ownership.share_percentage DESC, ownership.start_date DESC LIMIT 1) o ON true
    WHERE p.deleted_at IS NULL AND p.site_id = u.site_id
      AND (p.id = u.owner_person_id OR o.share_percentage IS NOT NULL)
) owners ON true
LEFT JOIN persons contact ON contact.id = u.primary_contact_person_id AND contact.site_id = u.site_id AND contact.deleted_at IS NULL
LEFT JOIN LATERAL (
    SELECT string_agg(DISTINCT p.full_name, ' ') AS member_names,
           string_agg(DISTINCT p.name_key, ' ') AS member_keys,
           string_agg(DISTINCT p.phone, ' ') AS member_phones,
           string_agg(DISTINCT p.phone_key, ' ') AS member_phone_keys,
           string_agg(DISTINCT p.email, ' ') AS member_emails
    FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id
    JOIN persons p ON p.id = m.person_id AND p.site_id = u.site_id
    WHERE o.unit_id = u.id AND o.is_active AND o.end_date IS NULL AND p.deleted_at IS NULL
) members ON true
WHERE u.deleted_at IS NULL;

CREATE OR REPLACE VIEW v_person_integrity_violations WITH (security_invoker = true) AS
SELECT 'person_without_site'::TEXT AS check_name, p.id::TEXT AS subject
FROM persons p WHERE p.site_id IS NULL AND p.person_type IS DISTINCT FROM 'SAAS_ADMIN'
UNION ALL
SELECT 'member_without_person', m.id::TEXT FROM occupancy_members m WHERE m.person_id IS NULL
UNION ALL
SELECT 'person_with_multiple_active_logins', u.person_id::TEXT
FROM users u WHERE u.is_active AND u.person_id IS NOT NULL
GROUP BY u.person_id HAVING count(*) > 1
UNION ALL
SELECT 'unit_primary_contact_not_on_unit', u.id::TEXT
FROM units u
WHERE u.primary_contact_person_id IS NOT NULL
  AND NOT (
      u.primary_contact_person_id IN (u.owner_person_id, u.tenant_person_id)
      OR EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = u.id AND o.person_id = u.primary_contact_person_id AND o.is_active)
      OR EXISTS (SELECT 1 FROM unit_occupancies o WHERE o.unit_id = u.id AND o.person_id = u.primary_contact_person_id AND o.is_active AND o.end_date IS NULL)
      OR EXISTS (SELECT 1 FROM occupancy_members m JOIN unit_occupancies o ON o.id = m.occupancy_id
                 WHERE o.unit_id = u.id AND m.person_id = u.primary_contact_person_id AND o.is_active AND o.end_date IS NULL)
  )
UNION ALL
SELECT 'legacy_primary_contact_unmatched', u.id::TEXT
FROM units u
WHERE u.primary_responsible_contact IS NOT NULL AND u.primary_contact_person_id IS NULL
UNION ALL
SELECT 'reference_to_merged_person', 'unit_owner:' || u.id::TEXT
FROM units u JOIN persons p ON p.id = u.owner_person_id
WHERE p.merged_into_person_id IS NOT NULL
UNION ALL
SELECT 'reference_to_merged_person', 'unit_tenant:' || u.id::TEXT
FROM units u JOIN persons p ON p.id = u.tenant_person_id
WHERE p.merged_into_person_id IS NOT NULL
UNION ALL
SELECT 'reference_to_merged_person', 'unit_primary_contact:' || u.id::TEXT
FROM units u JOIN persons p ON p.id = u.primary_contact_person_id
WHERE p.merged_into_person_id IS NOT NULL
UNION ALL
SELECT 'reference_to_merged_person', 'ownership:' || ownership.id::TEXT
FROM unit_ownerships ownership JOIN persons p ON p.id = ownership.person_id
WHERE p.merged_into_person_id IS NOT NULL
UNION ALL
SELECT 'reference_to_merged_person', 'occupancy:' || occupancy.id::TEXT
FROM unit_occupancies occupancy JOIN persons p ON p.id = occupancy.person_id
WHERE p.merged_into_person_id IS NOT NULL
UNION ALL
SELECT 'reference_to_merged_person', 'member:' || member.id::TEXT
FROM occupancy_members member JOIN persons p ON p.id = member.person_id
WHERE p.merged_into_person_id IS NOT NULL
UNION ALL
SELECT 'reference_to_merged_person', 'user:' || active_user.id::TEXT
FROM users active_user JOIN persons p ON p.id = active_user.person_id
WHERE p.merged_into_person_id IS NOT NULL AND active_user.is_active;
