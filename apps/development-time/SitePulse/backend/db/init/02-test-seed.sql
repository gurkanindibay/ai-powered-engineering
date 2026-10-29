-- ============================================================================
-- SitePulse Test & Development Seed Data (02-test-seed.sql)
-- FOR TEST & DEVELOPMENT ENVIRONMENTS ONLY:
-- Contains mock residential sites (Begonya Sitesi, Kardelen Rezidans),
-- blocks, demo residents, units, bank accounts, and overdue dues liabilities.
-- Auto-Increment BIGINT Identity Primary Keys & Consistent Turkish Periods
-- DO NOT EXECUTE IN PRODUCTION!
-- ============================================================================

-- 1. Test Residential Sites
INSERT INTO sites (id, name, address, slug, status, plan_type, license_end_date)
VALUES 
    (1, 'Begonya Sitesi', 'Ataşehir, Begonya Sok. No:14, İstanbul', 'begonya-sitesi', 'ACTIVE', 'PREMIUM', '2027-09-01'),
    (2, 'Kardelen Rezidans', 'Çankaya, Kardelen Cad. No:8, Ankara', 'kardelen-rezidans', 'ACTIVE', 'STANDARD', '2027-10-15')
ON CONFLICT (id) DO UPDATE
SET name = EXCLUDED.name,
    address = EXCLUDED.address,
    slug = EXCLUDED.slug,
    status = EXCLUDED.status,
    plan_type = EXCLUDED.plan_type;

-- 2. Test Blocks
INSERT INTO blocks (id, site_id, block_name, total_floors) 
VALUES 
    (1, 1, 'A Blok', 12),
    (2, 1, 'B Blok', 10)
ON CONFLICT (id) DO UPDATE
SET block_name = EXCLUDED.block_name,
    total_floors = EXCLUDED.total_floors;

-- 3. Test Persons & Users
-- Site Manager (Mehmet Demir)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    (3, '55555555555', 'Mehmet Demir', '+90 532 100 2030', 'mehmet.demir@begonya.com', 'HOME_OWNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES 
    (2, 1, 'Mehmet Demir', 'mehmet.demir@begonya.com', '+90 532 100 2030', 'ARGON2_HASH_mehmet123', 'SITE_MANAGER', FALSE)
ON CONFLICT (email) DO NOTHING;

-- Home Owner (Ahmet Yılmaz)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    (1, '12345678901', 'Ahmet Yılmaz', '+90 532 111 22 33', 'ahmet.yilmaz@begonya.com', 'HOME_OWNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES 
    (3, 1, 'Ahmet Yılmaz', 'ahmet.yilmaz@begonya.com', '+90 532 111 22 33', 'ARGON2_HASH_ahmet123', 'HOME_OWNER', FALSE)
ON CONFLICT (email) DO NOTHING;

-- Tenant (Zeynep Kaya)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    (2, '98765432109', 'Zeynep Kaya', '+90 542 333 44 55', 'zeynep@example.com', 'TENANT')
ON CONFLICT (id) DO NOTHING;

-- Home Owner (Mehmet Öz)
INSERT INTO persons (id, national_id, full_name, phone, email, person_type)
VALUES 
    (4, '44444444444', 'Mehmet Öz', '+90 533 222 33 44', 'mehmet.oz@begonya.com', 'HOME_OWNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES 
    (4, 1, 'Mehmet Öz', 'mehmet.oz@begonya.com', '+90 533 222 33 44', 'ARGON2_HASH_mehmetoz123', 'HOME_OWNER', FALSE)
ON CONFLICT (email) DO NOTHING;

-- 4. Test Units (Flats)
INSERT INTO units (id, block_id, site_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, virtual_iban) 
VALUES 
    (14, 1, 1, 14, 4, 24, 1, NULL, 'TR620020500009863791600001'),
    (3, 2, 1, 3, 1, 18, 4, NULL, 'TR620020500009863791600002')
ON CONFLICT (id) DO UPDATE
SET owner_person_id = EXCLUDED.owner_person_id,
    tenant_person_id = EXCLUDED.tenant_person_id,
    virtual_iban = EXCLUDED.virtual_iban;

-- 5. Test Site Bank Account (Begonya Sitesi - Kuveyt Türk)
INSERT INTO site_bank_accounts (id, site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by)
VALUES (
    1,
    1,
    'KUVEYT_TURK',
    'Kuveyt Türk Katılım Bankası',
    'TR620020500009863791600001',
    'Begonya Sitesi Yönetimi',
    'EXCEL',
    TRUE,
    2
) ON CONFLICT (id) DO UPDATE
SET iban = EXCLUDED.iban,
    account_holder = EXCLUDED.account_holder,
    is_active = EXCLUDED.is_active;

-- 6. Dues Liabilities & Transactions (Clean Slate: 0 debts, 0 transactions)
TRUNCATE TABLE collection_transactions RESTART IDENTITY CASCADE;
TRUNCATE TABLE dues_liabilities RESTART IDENTITY CASCADE;

-- 7. Synchronize Identity Sequences
SELECT setval(pg_get_serial_sequence('sites', 'id'), COALESCE((SELECT MAX(id) FROM sites), 1));
SELECT setval(pg_get_serial_sequence('blocks', 'id'), COALESCE((SELECT MAX(id) FROM blocks), 1));
SELECT setval(pg_get_serial_sequence('persons', 'id'), COALESCE((SELECT MAX(id) FROM persons), 1));
SELECT setval(pg_get_serial_sequence('users', 'id'), COALESCE((SELECT MAX(id) FROM users), 1));
SELECT setval(pg_get_serial_sequence('units', 'id'), COALESCE((SELECT MAX(id) FROM units), 1));
SELECT setval(pg_get_serial_sequence('site_bank_accounts', 'id'), COALESCE((SELECT MAX(id) FROM site_bank_accounts), 1));
SELECT setval(pg_get_serial_sequence('dues_liabilities', 'id'), 1, false);
SELECT setval(pg_get_serial_sequence('collection_transactions', 'id'), 1, false);
