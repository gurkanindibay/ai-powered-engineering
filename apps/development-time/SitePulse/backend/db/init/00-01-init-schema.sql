-- V1: Initial PostgreSQL Schema for SitePulse Residential Management (English Schema Standard)

CREATE TABLE sites (
    id VARCHAR(36) PRIMARY KEY,
    name VARCHAR(150) NOT NULL,
    address TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE blocks (
    id VARCHAR(36) PRIMARY KEY,
    site_id VARCHAR(36) NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
    block_name VARCHAR(50) NOT NULL,
    total_floors INT NOT NULL DEFAULT 1,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE persons (
    id VARCHAR(36) PRIMARY KEY,
    national_id VARCHAR(11) UNIQUE,
    full_name VARCHAR(120) NOT NULL,
    phone VARCHAR(20),
    email VARCHAR(120),
    person_type VARCHAR(20) NOT NULL -- 'HOME_OWNER', 'TENANT', 'RESIDENT'
);

CREATE TABLE units (
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

CREATE TABLE dues_liabilities (
    id VARCHAR(36) PRIMARY KEY,
    unit_id VARCHAR(36) NOT NULL REFERENCES units(id) ON DELETE CASCADE,
    period VARCHAR(50) NOT NULL, -- e.g. 'September 2026'
    principal_amount NUMERIC(15, 2) NOT NULL,
    due_date DATE NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'PENDING', -- 'PENDING', 'OVERDUE', 'PAID'
    delay_penalty NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    paid_amount NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
    payment_date TIMESTAMP WITH TIME ZONE,
    version INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Immutable Ledger for payment transactions (Audit Log)
CREATE TABLE collection_transactions (
    id VARCHAR(36) PRIMARY KEY,
    dues_liability_id VARCHAR(36) NOT NULL REFERENCES dues_liabilities(id),
    transaction_type VARCHAR(30) NOT NULL, -- 'CREDIT_CARD_POS', 'BANK_TRANSFER', 'CASH'
    paid_amount NUMERIC(15, 2) NOT NULL,
    reference_code VARCHAR(100),
    transaction_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Performance indices for mobile queries
CREATE INDEX idx_dues_unit_status ON dues_liabilities (unit_id, status);
CREATE INDEX idx_dues_due_date ON dues_liabilities (due_date);
