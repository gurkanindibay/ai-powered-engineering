-- V55: Own the system reference tables in the migration history.
--
-- `system_supported_banks` and `system_configurations` used to be created by the system
-- seed (db/seed/01-system-seed.sql). The seed also runs at startup for a runtime identity
-- that is not a schema owner, and `CREATE TABLE IF NOT EXISTS` needs CREATE on the schema
-- even when the table is present, so startup failed as soon as the runtime role stopped
-- being a superuser. The schema belongs to the migrations; the seed keeps only rows.

CREATE TABLE IF NOT EXISTS system_supported_banks (
    bank_code VARCHAR(50) PRIMARY KEY,
    bank_name VARCHAR(120) NOT NULL,
    default_statement_format VARCHAR(30) NOT NULL, -- 'EXCEL', 'CSV', 'MT940'
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS system_configurations (
    config_key VARCHAR(80) PRIMARY KEY,
    config_value VARCHAR(255) NOT NULL,
    description TEXT,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
