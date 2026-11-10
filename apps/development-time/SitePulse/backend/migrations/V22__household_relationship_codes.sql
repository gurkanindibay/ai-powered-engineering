-- V22: household relationships are fixed codes (person module F5).
-- Stored values were free text (mostly Turkish labels); they become one of
-- SPOUSE, CHILD, PARENT, RELATIVE, OTHER. Anything unrecognised becomes OTHER.

CREATE OR REPLACE FUNCTION sp_relationship_code(value TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN value IS NULL OR btrim(value) = '' THEN 'OTHER'
        WHEN upper(btrim(value)) IN ('SPOUSE', 'CHILD', 'PARENT', 'RELATIVE', 'OTHER') THEN upper(btrim(value))
        WHEN lower(btrim(value)) IN ('eşi', 'eş', 'eşim', 'esi') THEN 'SPOUSE'
        WHEN lower(btrim(value)) IN ('çocuğu', 'çocuk', 'oğlu', 'kızı', 'cocugu') THEN 'CHILD'
        WHEN lower(btrim(value)) IN ('anne/baba', 'annesi', 'babası', 'ebeveyni', 'ebeveyn') THEN 'PARENT'
        WHEN lower(btrim(value)) IN ('kardeşi', 'kardeş', 'akrabası', 'akraba', 'family') THEN 'RELATIVE'
        ELSE 'OTHER'
    END
$$;

UPDATE occupancy_members SET relationship = sp_relationship_code(relationship)
WHERE relationship IS DISTINCT FROM sp_relationship_code(relationship);
UPDATE invitation_tokens SET relationship = sp_relationship_code(relationship)
WHERE relationship IS NOT NULL AND relationship IS DISTINCT FROM sp_relationship_code(relationship);

ALTER TABLE occupancy_members DROP CONSTRAINT IF EXISTS chk_occupancy_members_relationship;
ALTER TABLE occupancy_members ADD CONSTRAINT chk_occupancy_members_relationship
    CHECK (relationship IN ('SPOUSE', 'CHILD', 'PARENT', 'RELATIVE', 'OTHER'));
