-- Synthetic variation of the 88-unit onboarding fixture.
-- This is loaded only into the database created by the E2E stack.
BEGIN;

INSERT INTO sites (name, slug, status, plan_type, license_end_date, go_live_date)
SELECT 'Nightly site ' || n, 'nightly-volume-' || n, 'ACTIVE', 'STANDARD',
       DATE '2099-01-01', DATE '2026-11-01'
FROM generate_series(1, 50) AS numbers(n);

INSERT INTO blocks (site_id, block_name, total_floors)
SELECT id, 'A', 50 FROM sites WHERE slug LIKE 'nightly-volume-%';

INSERT INTO house_types (site_id, type_name, dues_amount)
SELECT id, '2+1', 1400.00 FROM sites WHERE slug LIKE 'nightly-volume-%';

INSERT INTO persons (site_id, full_name, email, person_type)
SELECT id, 'Nightly manager ' || id, 'manager-' || id || '@nightly.test', 'SITE_MANAGER'
FROM sites WHERE slug LIKE 'nightly-volume-%';

-- Copy the password hash of the existing test-only manager account.
INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
SELECT p.site_id, p.id, p.email, seed.password_hash, 'SITE_MANAGER', FALSE
FROM persons p
JOIN sites ON sites.id = p.site_id
CROSS JOIN (SELECT u.password_hash FROM users u JOIN sites s ON s.id = u.site_id
            WHERE s.slug = 'begonya-sitesi' AND u.role = 'SITE_MANAGER') seed
WHERE sites.slug LIKE 'nightly-volume-%';

INSERT INTO persons (site_id, full_name, email, person_type)
SELECT s.id, 'Nightly owner ' || n, 'owner-' || n || '-' || s.id || '@nightly.test', 'HOME_OWNER'
FROM sites s CROSS JOIN generate_series(1, 200) AS numbers(n)
WHERE s.slug LIKE 'nightly-volume-%';

INSERT INTO units (site_id, block_id, unit_number, floor, land_share, owner_person_id,
                   virtual_iban, house_type, house_type_id, occupancy_status, created_at)
SELECT s.id, b.id, n, (n - 1) / 4 + 1, 1, p.id,
       'TR00' || lpad(s.id::text, 12, '0') || lpad(n::text, 10, '0'),
       h.type_name, h.id, 'OWNER_OCCUPIED', TIMESTAMPTZ '2026-11-01 00:00:00+00'
FROM sites s
JOIN blocks b ON b.site_id = s.id
JOIN house_types h ON h.site_id = s.id
CROSS JOIN generate_series(1, 200) AS numbers(n)
JOIN persons p ON p.site_id = s.id AND p.email = 'owner-' || n || '-' || s.id || '@nightly.test'
WHERE s.slug LIKE 'nightly-volume-%';

INSERT INTO unit_ownerships (unit_id, person_id, start_date)
SELECT u.id, u.owner_person_id, DATE '2026-11-01'
FROM units u JOIN sites s ON s.id = u.site_id WHERE s.slug LIKE 'nightly-volume-%';

INSERT INTO unit_occupancies (unit_id, person_id, occupancy_type, start_date)
SELECT u.id, u.owner_person_id, 'OWNER', DATE '2026-11-01'
FROM units u JOIN sites s ON s.id = u.site_id WHERE s.slug LIKE 'nightly-volume-%';

COMMIT;
