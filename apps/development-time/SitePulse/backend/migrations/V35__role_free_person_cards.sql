-- V35: Role-free person cards (unified people, step E).
-- A person card no longer needs a stored role. The role is derived from what the
-- person holds (v_person_roles), so `person_type` becomes nullable and cards that
-- only carried the HOME_RESIDENT placeholder lose it. Occupancy, ownership and the
-- append-only payment ledger are not touched.

ALTER TABLE persons ALTER COLUMN person_type DROP NOT NULL;

-- chk_persons_person_type already accepts NULL (a CHECK passes on NULL); restate
-- it so the allowed values stay explicit next to the nullable column.
ALTER TABLE persons DROP CONSTRAINT IF EXISTS chk_persons_person_type;
ALTER TABLE persons ADD CONSTRAINT chk_persons_person_type
    CHECK (person_type IS NULL OR person_type IN ('HOME_OWNER', 'HOME_RESIDENT', 'SITE_MANAGER', 'SAAS_ADMIN'));

-- Clear the placeholder only where the person holds no role and has no login.
UPDATE persons p
SET person_type = NULL
WHERE p.person_type = 'HOME_RESIDENT'
  AND p.deleted_at IS NULL
  AND NOT EXISTS (SELECT 1 FROM users u WHERE u.person_id = p.id)
  AND NOT EXISTS (
      SELECT 1 FROM v_person_roles r
      WHERE r.person_id = p.id
        AND (r.owned_units + r.occupied_units + r.member_units) > 0);

COMMENT ON COLUMN persons.person_type IS
    'Legacy stored role; NULL for role-free cards. Read the derived role from v_person_roles.derived_role.';
