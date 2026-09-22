-- V3: Multi-Provider Authentication (Password & Google OAuth2) & Permission Model
ALTER TABLE kullanicilar
    ADD COLUMN IF NOT EXISTS auth_provider VARCHAR(30) NOT NULL DEFAULT 'LOCAL',
    ADD COLUMN IF NOT EXISTS google_sub VARCHAR(100),
    ADD COLUMN IF NOT EXISTS avatar_url VARCHAR(500);

-- Allow null password hash for users registered exclusively through Google OAuth2
ALTER TABLE kullanicilar ALTER COLUMN sifre_hash DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_kullanici_google_sub ON kullanicilar (google_sub) WHERE google_sub IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_kullanici_auth_provider ON kullanicilar (auth_provider);
