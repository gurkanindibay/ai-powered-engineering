-- V3: Multi-Provider Authentication (Password & Google OAuth2) & Permission Model (English Schema Standard)
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS auth_provider VARCHAR(30) NOT NULL DEFAULT 'LOCAL',
    ADD COLUMN IF NOT EXISTS google_sub VARCHAR(100),
    ADD COLUMN IF NOT EXISTS avatar_url VARCHAR(500);

-- Allow null password hash for users registered exclusively through Google OAuth2
ALTER TABLE users ALTER COLUMN password_hash DROP NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS uq_user_google_sub ON users (google_sub) WHERE google_sub IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_user_auth_provider ON users (auth_provider);
