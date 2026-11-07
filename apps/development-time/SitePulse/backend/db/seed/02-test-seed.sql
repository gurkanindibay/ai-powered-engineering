-- ============================================================================
-- SitePulse Test & Development Seed Data (02-test-seed.sql)
-- FOR TEST & DEVELOPMENT ENVIRONMENTS ONLY:
-- Contains mock residential sites (Begonya Sitesi, Kardelen Rezidans),
-- blocks, demo residents, units, bank accounts, and overdue dues liabilities.
-- Auto-Increment BIGINT Identity Primary Keys & Consistent Turkish Periods
-- DO NOT EXECUTE IN PRODUCTION!
-- ============================================================================

-- 1. Test Residential Sites (Auto-Increment Identity id)
INSERT INTO sites (name, address, slug, status, plan_type, license_end_date)
VALUES 
    ('Begonya Sitesi', 'Ataşehir, Begonya Sok. No:14, İstanbul', 'begonya-sitesi', 'ACTIVE', 'PREMIUM', '2027-09-01'),
    ('Kardelen Rezidans', 'Çankaya, Kardelen Cad. No:8, Ankara', 'kardelen-rezidans', 'ACTIVE', 'STANDARD', '2027-10-15')
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name,
    address = EXCLUDED.address,
    status = EXCLUDED.status,
    plan_type = EXCLUDED.plan_type,
    license_end_date = EXCLUDED.license_end_date;

-- 1b. Tariff categories for every site (priced per unit size)
INSERT INTO house_types (site_id, type_name, dues_amount, description)
SELECT s.id, t.type_name, t.dues_amount, t.description
FROM sites s
CROSS JOIN (
    VALUES
        ('1+1', 1000.00::NUMERIC(15,2), '1 Oda 1 Salon'),
        ('2+1', 1400.00::NUMERIC(15,2), '2 Oda 1 Salon'),
        ('3+1', 1800.00::NUMERIC(15,2), '3 Oda 1 Salon'),
        ('4+1', 2200.00::NUMERIC(15,2), '4 Oda 1 Salon'),
        ('Dublex', 2500.00::NUMERIC(15,2), 'Çatı Dubleks / Bahçe Katı')
) AS t(type_name, dues_amount, description)
ON CONFLICT (site_id, type_name) DO NOTHING;

-- 2. Test Blocks (Auto-Increment Identity id, site resolved dynamically via slug)
INSERT INTO blocks (site_id, block_name, total_floors) 
SELECT s.id, b.block_name, b.total_floors
FROM sites s
CROSS JOIN (
    VALUES 
        ('A Blok', 12),
        ('B Blok', 10)
) AS b(block_name, total_floors)
WHERE s.slug = 'begonya-sitesi'
ON CONFLICT (site_id, block_name) DO UPDATE
SET total_floors = EXCLUDED.total_floors;

-- 3. Test Persons & Users (Auto-Increment Identity id, foreign keys resolved dynamically)
-- Development-only credentials (argon2id hashes of mehmet123 / ahmet123 / mehmetoz123).
INSERT INTO persons (national_id, full_name, phone, email, person_type)
VALUES 
    ('55555555555', 'Mehmet Demir', '+90 532 100 2030', 'mehmet.demir@begonya.com', 'HOME_OWNER'),
    ('12345678901', 'Ahmet Yılmaz', '+90 532 111 22 33', 'ahmet.yilmaz@begonya.com', 'HOME_OWNER'),
    ('98765432109', 'Zeynep Kaya', '+90 542 333 44 55', 'zeynep@example.com', 'HOME_RESIDENT'),
    ('44444444444', 'Mehmet Öz', '+90 533 222 33 44', 'mehmet.oz@begonya.com', 'HOME_OWNER')
ON CONFLICT (email) DO UPDATE
SET full_name = EXCLUDED.full_name,
    phone = EXCLUDED.phone,
    person_type = EXCLUDED.person_type;

INSERT INTO users (site_id, person_id, email, password_hash, role, must_change_password)
SELECT 
    s.id,
    p.id,
    u.email,
    u.password_hash,
    u.role,
    u.must_change_password
FROM (
    VALUES
        ('begonya-sitesi', 'mehmet.demir@begonya.com', '$argon2id$v=19$m=19456,t=2,p=1$oti/xPMmkVNKfWBjdyF3tA$8fO5zoZsnd/RpTdpnsOeURv7wyWzkHicAFacs0xx6q0', 'SITE_MANAGER', FALSE),
        ('begonya-sitesi', 'ahmet.yilmaz@begonya.com', '$argon2id$v=19$m=19456,t=2,p=1$YsMeFsEB5mFZyolRkMHQdg$B+e2RQqZ4RhmRJm27iab3Oam+ZiatTZFjdxUzZfNVag', 'HOME_OWNER', FALSE),
        ('begonya-sitesi', 'mehmet.oz@begonya.com', '$argon2id$v=19$m=19456,t=2,p=1$yhcA3VWK507NdmDfi0k1aQ$qRbHm998tv7yn0wexSHEyOZ73qfZqiuCIY4zz8oHAow', 'HOME_OWNER', FALSE)
) AS u(site_slug, email, password_hash, role, must_change_password)
JOIN sites s ON s.slug = u.site_slug
JOIN persons p ON p.email = u.email
ON CONFLICT (email) DO UPDATE
SET site_id = EXCLUDED.site_id,
    person_id = EXCLUDED.person_id,
    password_hash = EXCLUDED.password_hash,
    role = EXCLUDED.role,
    must_change_password = EXCLUDED.must_change_password;

-- 4. Test Units (Auto-Increment Identity id, relations resolved dynamically)
INSERT INTO units (block_id, site_id, unit_number, floor, land_share, owner_person_id, tenant_person_id, virtual_iban)
SELECT 
    b.id,
    s.id,
    u.unit_number,
    u.floor,
    u.land_share,
    p_owner.id,
    NULL,
    u.virtual_iban
FROM (
    VALUES
        ('begonya-sitesi', 'A Blok', 14, 4, 24, 'ahmet.yilmaz@begonya.com', 'TR620020500009863791600001'),
        ('begonya-sitesi', 'B Blok', 3, 1, 18, 'mehmet.oz@begonya.com', 'TR620020500009863791600002')
) AS u(site_slug, block_name, unit_number, floor, land_share, owner_email, virtual_iban)
JOIN sites s ON s.slug = u.site_slug
JOIN blocks b ON b.site_id = s.id AND b.block_name = u.block_name
LEFT JOIN persons p_owner ON p_owner.email = u.owner_email
ON CONFLICT (block_id, unit_number) DO UPDATE
SET floor = EXCLUDED.floor,
    land_share = EXCLUDED.land_share,
    owner_person_id = EXCLUDED.owner_person_id,
    tenant_person_id = EXCLUDED.tenant_person_id,
    virtual_iban = EXCLUDED.virtual_iban;

-- 5. Test Site Bank Account (Auto-Increment Identity id, site and configured_by resolved dynamically)
INSERT INTO site_bank_accounts (site_id, bank_code, bank_name, iban, account_holder, statement_format, is_active, configured_by)
SELECT 
    s.id,
    'KUVEYT_TURK',
    'Kuveyt Türk Katılım Bankası',
    'TR620020500009863791600001',
    'Begonya Sitesi Yönetimi',
    'EXCEL',
    TRUE,
    u.id
FROM sites s
JOIN users u ON u.email = 'mehmet.demir@begonya.com'
WHERE s.slug = 'begonya-sitesi'
ON CONFLICT (site_id, account_type) WHERE is_active = true DO UPDATE
SET iban = EXCLUDED.iban,
    account_holder = EXCLUDED.account_holder,
    is_active = EXCLUDED.is_active;

-- 6. Dues Liabilities & Transactions (Clean Slate: 0 debts, 0 transactions)
TRUNCATE TABLE payment_entries RESTART IDENTITY CASCADE;
TRUNCATE TABLE dues_liabilities RESTART IDENTITY CASCADE;
