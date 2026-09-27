-- SitePulse Seed Test Data for Local Development & Testing (English Schema Standard)

-- 1. Create Tables (matches Flyway V1)
CREATE TABLE IF NOT EXISTS sites (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    address TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS blocks (
    id VARCHAR(36) PRIMARY KEY,
    site_id VARCHAR(36) NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    block_name VARCHAR(50) NOT NULL,
    total_floors INT NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS persons (
    id VARCHAR(36) PRIMARY KEY,
    national_id VARCHAR(11) UNIQUE,
    full_name VARCHAR(120) NOT NULL,
    phone VARCHAR(20),
    email VARCHAR(120),
    person_type VARCHAR(20) NOT NULL
);

CREATE TABLE IF NOT EXISTS units (
    id VARCHAR(36) PRIMARY KEY,
    block_id VARCHAR(36) NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
    unit_number INT NOT NULL,
    floor INT NOT NULL,
    land_share INT NOT NULL DEFAULT 1,
    owner_person_id VARCHAR(36) NOT NULL REFERENCES persons(id),
    tenant_person_id VARCHAR(36) REFERENCES persons(id),
    version INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_block_unit UNIQUE (block_id, unit_number)
);

CREATE TABLE IF NOT EXISTS dues_liabilities (
    id VARCHAR(36) PRIMARY KEY,
    unit_id VARCHAR(36) NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    period VARCHAR(50) NOT NULL,
    principal_amount NUMERIC(15, 2) NOT NULL,
    due_date DATE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    delay_penalty NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    paid_amount NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    payment_date TIMESTAMP WITH TIME ZONE,
    version INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS collection_transactions (
    id VARCHAR(36) PRIMARY KEY,
    dues_liability_id VARCHAR(36) NOT NULL REFERENCES dues_liabilities(id),
    transaction_type VARCHAR(30) NOT NULL,
    paid_amount NUMERIC(15, 2) NOT NULL,
    reference_code VARCHAR(100),
    transaction_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- 2. Insert Seed Data
INSERT INTO sites (id, name, address) 
VALUES ('site-01', 'Begonya Sitesi', 'Ataşehir, İstanbul')
ON CONFLICT (id) DO NOTHING;

INSERT INTO blocks (id, site_id, block_name, total_floors) 
VALUES 
  ('blok-A', 'site-01', 'A Blok', 12),
  ('blok-B', 'site-01', 'B Blok', 10)
ON CONFLICT (id) DO NOTHING;

INSERT INTO persons (id, national_id, full_name, phone, email, person_type) 
VALUES 
  ('kisi-01', '12345678901', 'Ahmet Yılmaz', '05321112233', 'ahmet@example.com', 'HOME_OWNER'),
  ('kisi-02', '98765432109', 'Zeynep Kaya', '05423334455', 'zeynep@example.com', 'TENANT'),
  ('kisi-03', '55555555555', 'Mehmet Demir', '05559998877', 'mehmet@example.com', 'HOME_OWNER')
ON CONFLICT (id) DO NOTHING;

INSERT INTO units (id, block_id, unit_number, floor, land_share, owner_person_id, tenant_person_id) 
VALUES 
  ('d-14', 'blok-A', 14, 4, 24, 'kisi-01', 'kisi-02'),
  ('d-03', 'blok-B', 3, 1, 18, 'kisi-03', NULL)
ON CONFLICT (id) DO NOTHING;

-- Seed Dues matching SPEC-001 (₺1400.00 base, 10 days overdue relative to mid-September)
INSERT INTO dues_liabilities (id, unit_id, period, principal_amount, due_date, status, delay_penalty) 
VALUES 
  ('borc-101', 'd-14', 'September 2026', 1400.00, '2026-09-15', 'OVERDUE', 23.33),
  ('borc-102', 'd-03', 'September 2026', 1100.00, '2026-09-30', 'PENDING', 0.00)
ON CONFLICT (id) DO NOTHING;
