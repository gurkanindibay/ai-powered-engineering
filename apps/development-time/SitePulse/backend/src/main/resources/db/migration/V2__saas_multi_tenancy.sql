-- V2: SaaS Multi-Tenancy Enhancements & User Identity

ALTER TABLE siteler
    ADD COLUMN IF NOT EXISTS slug VARCHAR(180) UNIQUE,
    ADD COLUMN IF NOT EXISTS durum VARCHAR(30) NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN IF NOT EXISTS plan_tipi VARCHAR(50) NOT NULL DEFAULT 'STANDARD',
    ADD COLUMN IF NOT EXISTS lisans_bitis_tarihi DATE;

-- Ensure default seed site has slug and active status
UPDATE siteler SET slug = 'begonya-sitesi', durum = 'ACTIVE', plan_tipi = 'PREMIUM' WHERE id = 'site-1';

-- Global User Identity Table for SaaS Admins, Site Managers, and Residents
CREATE TABLE IF NOT EXISTS kullanicilar (
    id VARCHAR(36) PRIMARY KEY,
    site_id VARCHAR(36) REFERENCES siteler(id) ON DELETE CASCADE,
    ad_soyad VARCHAR(120) NOT NULL,
    eposta VARCHAR(120) UNIQUE NOT NULL,
    telefon VARCHAR(20),
    sifre_hash VARCHAR(255) NOT NULL,
    rol VARCHAR(30) NOT NULL, -- 'SAAS_ADMIN', 'SITE_MANAGER', 'RESIDENT'
    sifre_degistirilmeli BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_kullanici_site ON kullanicilar (site_id);
CREATE INDEX IF NOT EXISTS idx_kullanici_eposta ON kullanicilar (eposta);

-- Seed Initial Super Admin and Begonya Site Manager
INSERT INTO kullanicilar (id, site_id, ad_soyad, eposta, telefon, sifre_hash, rol, sifre_degistirilmeli)
VALUES 
    ('usr-saas-root', NULL, 'SaaS Platform Admin', 'admin@sitepulse.io', '+90 850 555 0000', 'argon2id_hash_placeholder', 'SAAS_ADMIN', FALSE),
    ('usr-site-manager-1', 'site-1', 'Mehmet Demir', 'mehmet.demir@begonya.com', '+90 532 100 2030', 'argon2id_hash_placeholder', 'SITE_MANAGER', FALSE)
ON CONFLICT (eposta) DO NOTHING;
