-- V24: contact preferences and consents per person (person module F7).
--
-- How the site reaches a person: preferred channel and language, and an
-- emergency contact. Channel consents stay in `communication_consents` (V20),
-- which only the person changes (KVKK); managers see them read-only. The
-- preference codes are audited; contact values stay out of the audit payload.

ALTER TABLE persons ADD COLUMN IF NOT EXISTS preferred_channel VARCHAR(10) NOT NULL DEFAULT 'EMAIL';
ALTER TABLE persons ADD COLUMN IF NOT EXISTS preferred_language VARCHAR(5) NOT NULL DEFAULT 'tr';
ALTER TABLE persons ADD COLUMN IF NOT EXISTS emergency_contact_name VARCHAR(255);
ALTER TABLE persons ADD COLUMN IF NOT EXISTS emergency_contact_phone VARCHAR(20);

SELECT sp_add_constraint('persons', 'chk_persons_preferred_channel',
    'CHECK (preferred_channel IN (''EMAIL'', ''SMS'', ''WHATSAPP'', ''PHONE''))');
SELECT sp_add_constraint('persons', 'chk_persons_preferred_language',
    'CHECK (preferred_language IN (''tr'', ''en''))');

-- Preference changes become part of the audit trail.
CREATE OR REPLACE FUNCTION sp_audit_projection(value JSONB) RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(jsonb_object_agg(key, CASE WHEN key = ANY(ARRAY['amount','principal_amount','delay_penalty','paid_principal','paid_penalty','allocated_advance','total_amount','total_budget','annual_amount','monthly_amount','rate_percent']) THEN to_jsonb(val #>> '{}') ELSE val END), '{}'::jsonb)
    FROM jsonb_each(value) AS fields(key, val)
    WHERE key = ANY(ARRAY['amount','principal_amount','delay_penalty','paid_principal','paid_penalty','allocated_advance','total_amount','total_budget','annual_amount','monthly_amount','rate_percent','status','role','is_active','must_change_password',
        'site_id','unit_id','owner_person_id','tenant_person_id','person_id',
        'debtor_type','payer_role','receipt_type','reverses_receipt_id',
        'settlement_status','matched_unit_id','auth_version','revoked_at',
        'approved_by','operator_user_id','expires_at','permissions','user_id','currency','auth_provider','budget_id','operating_budget_id','fiscal_year','year','allocation_basis',
        'preferred_channel','preferred_language'])
$$;
