-- V2: SaaS Multi-Tenancy Enhancements & User Identity (English Schema Standard)

ALTER TABLE sites
    ADD COLUMN IF NOT EXISTS slug VARCHAR(180) UNIQUE,
    ADD COLUMN IF NOT EXISTS status VARCHAR(30) NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN IF NOT EXISTS plan_type VARCHAR(50) NOT NULL DEFAULT 'STANDARD',
    ADD COLUMN IF NOT EXISTS license_end_date DATE;

-- Ensure default seed site has slug and active status
UPDATE sites SET slug = 'begonya-sitesi', status = 'ACTIVE', plan_type = 'PREMIUM' WHERE id = 'site-1';

-- Global User Identity Table for SaaS Admins, Site Managers, and Residents
CREATE TABLE IF NOT EXISTS users (
    id VARCHAR(36) PRIMARY KEY,
    site_id VARCHAR(36) REFERENCES sites(id) ON DELETE CASCADE,
    full_name VARCHAR(120) NOT NULL,
    email VARCHAR(120) UNIQUE NOT NULL,
    phone VARCHAR(20),
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(30) NOT NULL, -- 'SAAS_ADMIN', 'SITE_MANAGER', 'HOME_OWNER', 'HOME_RESIDENT'
    must_change_password BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_user_site ON users (site_id);
CREATE INDEX IF NOT EXISTS idx_user_email ON users (email);

-- Seed Initial Super Admin and Begonya Site Manager
INSERT INTO users (id, site_id, full_name, email, phone, password_hash, role, must_change_password)
VALUES 
    ('usr-saas-root', NULL, 'SaaS Platform Admin', 'admin@sitepulse.io', '+90 850 555 0000', 'argon2id_hash_placeholder', 'SAAS_ADMIN', FALSE),
    ('usr-site-manager-1', 'site-1', 'Mehmet Demir', 'mehmet.demir@begonya.com', '+90 532 100 2030', 'argon2id_hash_placeholder', 'SITE_MANAGER', FALSE)
ON CONFLICT (email) DO NOTHING;
