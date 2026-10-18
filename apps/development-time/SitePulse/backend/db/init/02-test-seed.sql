-- ============================================================================
-- SitePulse Test & Development Seed Data (02-test-seed.sql)
-- FOR TEST & DEVELOPMENT ENVIRONMENTS ONLY:
-- Contains mock residential sites (Begonya Sitesi, Kardelen Rezidans),
-- blocks, demo residents, units, bank accounts, and overdue dues liabilities.
-- DO NOT EXECUTE IN PRODUCTION!
-- ============================================================================

-- 1. Test Residential Sites
INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date)
VALUES 
    ('site-1', 'Begonya Sitesi', 'Ataşehir, Begonya Sok. No:14, İstanbul', 'begonya-sitesi', 'ACTIVE', 'PREMIUM', '2027-09-01'),
    ('site-2', 'Kardelen Rezidans', 'Çankaya, Kardelen Cad. No:8, Ankara', 'kardelen-rezidans', 'ACTIVE', 'STANDARD', '2027-10-15')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    address = EXCLUDED.address,
    slug = EXCLUDED.slug,
    status = EXCLUDED.status,
    plan_type = EXCLUDED.plan_type;

-- 2. Test Blocks
INSERT INTO blocks (id, site_id, block_name, total_floors) 
VALUES 
    ('blok-A', 'site-1', 'A Blok', 12),
    ('blok-B', 'site-1', 'B Blok', 10)
ON CONFLICT (id) DO UPDATE
SET block_name = EXCLUDED.block_name,
    total_floors = EXCLUDED.total_floors;

-- 3. Test Persons & Users
-- Site Manager (Mehmet Demir)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    ('kisi-03', '55555555555', 'Mehmet Demir', '+90 532 100 2030', 'mehmet.demir@begonya.com', 'HOME_OWNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES 
    ('usr-site-manager-1', 'site-1', 'Mehmet Demir', 'mehmet.demir@begonya.com', '+90 532 100 2030', 'ARGON2_HASH_mehmet123', 'SITE_MANAGER', FALSE)
ON CONFLICT (email) DO NOTHING;

-- Home Owner (Ahmet Yılmaz)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    ('kisi-01', '12345678901', 'Ahmet Yılmaz', '+90 532 111 22 33', 'ahmet.yilmaz@begonya.com', 'HOME_OWNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES 
    ('usr-home-owner-1', 'site-1', 'Ahmet Yılmaz', 'ahmet.yilmaz@begonya.com', '+90 532 111 22 33', 'ARGON2_HASH_ahmet123', 'HOME_OWNER', FALSE)
ON CONFLICT (email) DO NOTHING;

-- Tenant (Zeynep Kaya)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    ('kisi-02', '98765432109', 'Zeynep Kaya', '+90 542 333 44 55', 'zeynep@example.com', 'TENANT')
ON CONFLICT (id) DO NOTHING;

-- 4. Test Units (Flats)
INSERT INTO units (id, block_id, unit_number, floor, land_share, owner_person_id, tenant_person_id) 
VALUES 
    ('d-14', 'blok-A', 14, 4, 24, 'kisi-01', 'kisi-02'),
    ('d-03', 'blok-B', 3, 1, 18, 'kisi-03', NULL)
ON CONFLICT (id) DO UPDATE
SET owner_person_id = EXCLUDED.owner_person_id,
    tenant_person_id = EXCLUDED.tenant_person_id;

-- 5. Test Site Bank Account (Begonya Sitesi - Kuveyt Türk)
INSERT INTO site_bank_accounts (id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by)
VALUES (
    'sba-site-1-kt',
    'site-1',
    'KUVEYT_TURK',
    'Kuveyt Türk Katılım Bankası',
    'TR620020500009863791600001',
    'Begonya Sitesi Yönetimi',
    'EXCEL',
    TRUE,
    'usr-site-manager-1'
) ON CONFLICT (id) DO UPDATE
SET iban = EXCLUDED.iban,
    account_holder = EXCLUDED.account_holder,
    is_active = EXCLUDED.is_active;

-- 6. Test Dues Liabilities (September 2026 dues)
INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, due_date, status, delay_penalty) 
VALUES 
    ('borc-101', 'd-14', 'September 2026', 1400.00, '2026-09-15', 'OVERDUE', 23.33),
    ('borc-102', 'd-03', 'September 2026', 1100.00, '2026-09-30', 'PENDING', 0.00)
ON CONFLICT (id) DO UPDATE
SET principal_amount = EXCLUDED.principal_amount,
    status = EXCLUDED.status,
    delay_penalty = EXCLUDED.delay_penalty;
