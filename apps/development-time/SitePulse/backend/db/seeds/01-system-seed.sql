-- ============================================================================
-- SitePulse System Seed Data (01-system-seed.sql)
-- PRODUCTION SAFE: Essential platform definitions, lookups, and root identity.
-- Does NOT contain any mock sites, test flats, test residents, or debt records.
-- ============================================================================

-- 1. Supported Banks Reference Table & Lookups
CREATE TABLE IF NOT EXISTS system_supported_banks (
    bank_code VARCHAR(50) PRIMARY KEY,
    bank_name VARCHAR(120) NOT NULL,
    default_statement_format VARCHAR(30) NOT NULL, -- 'EXCEL', 'CSV', 'MT940'
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO system_supported_banks (bank_code, bank_name, default_statement_format, is_active)
VALUES
    ('KUVEYT_TURK', 'Kuveyt Türk Katılım Bankası', 'EXCEL', TRUE),
    ('IS_BANKASI', 'Türkiye İş Bankası', 'MT940', TRUE),
    ('GARANTI_BBVA', 'Garanti BBVA', 'EXCEL', TRUE),
    ('YAPI_KREDI', 'Yapı Kredi Bankası', 'CSV', TRUE),
    ('AKBANK', 'Akbank', 'CSV', TRUE),
    ('ZIRAAT', 'Ziraat Bankası', 'EXCEL', TRUE)
ON CONFLICT (bank_code) DO UPDATE
SET bank_name = EXCLUDED.bank_name,
    default_statement_format = EXCLUDED.default_statement_format,
    is_active = EXCLUDED.is_active;

-- 2. System Default Configuration Settings (Late Penalty, Currency, Grace Periods)
CREATE TABLE IF NOT EXISTS system_configurations (
    config_key VARCHAR(80) PRIMARY KEY,
    config_value VARCHAR(255) NOT NULL,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO system_configurations (config_key, config_value, description)
VALUES
    ('DEFAULT_MONTHLY_PENALTY_RATE', '0.05', 'Legal default monthly penalty interest rate (5%) under Turkish Property Law No. 634 Art. 20'),
    ('SYSTEM_CURRENCY', 'TRY', 'Default platform accounting currency code'),
    ('DEFAULT_DUE_DAY_OF_MONTH', '15', 'Default due day for monthly apartment dues'),
    ('VIRTUAL_IBAN_ENABLED', 'true', 'Flag to determine whether virtual IBAN issuance is active across tenants')
ON CONFLICT (config_key) DO UPDATE
SET config_value = EXCLUDED.config_value,
    description = EXCLUDED.description,
    updated_at = CURRENT_TIMESTAMP;

-- 3. Initial SaaS Platform Super Administrator
-- Note: In production deployments, change admin password immediately upon first login.
INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES (
    'usr-saas-root',
    NULL,
    'SaaS Platform Admin',
    'admin@sitepulse.io',
    '+90 850 555 0000',
    'argon2id_hash_placeholder',
    'SAAS_ADMIN',
    FALSE
)
ON CONFLICT (email) DO NOTHING;
