-- The selected contact does not change the owner, tenant or financial debtor.
ALTER TABLE units ADD COLUMN IF NOT EXISTS primary_responsible_contact JSONB;
ALTER TABLE units ADD CONSTRAINT chk_unit_responsible_contact CHECK (
    primary_responsible_contact IS NULL OR (
        jsonb_typeof(primary_responsible_contact) = 'object'
        AND primary_responsible_contact->>'primary_responsible_role' IN ('OWNER', 'TENANT', 'RESIDENT')
    )
);
