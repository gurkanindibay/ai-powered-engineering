-- Persistent credentials, explicit support access, and transaction-bound evidence.
ALTER TABLE users ADD COLUMN IF NOT EXISTS auth_version BIGINT NOT NULL DEFAULT 1;
ALTER TABLE users ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;

CREATE TABLE auth_sessions (
    id TEXT PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    auth_version BIGINT NOT NULL,
    site_id BIGINT,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    authenticated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    stepped_up_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX auth_sessions_user ON auth_sessions(user_id) WHERE revoked_at IS NULL;
CREATE TABLE auth_refresh_tokens (
    digest TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES auth_sessions(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL,
    consumed_at TIMESTAMPTZ
);
CREATE INDEX auth_refresh_session ON auth_refresh_tokens(session_id);
CREATE TABLE support_grants (
    id TEXT PRIMARY KEY,
    operator_user_id BIGINT NOT NULL REFERENCES users(id),
    site_id BIGINT NOT NULL REFERENCES sites(id),
    permissions TEXT[] NOT NULL,
    reason TEXT NOT NULL CHECK (length(reason) BETWEEN 10 AND 500),
    approved_by BIGINT REFERENCES users(id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    CHECK (approved_by IS NULL OR approved_by <> operator_user_id),
    CHECK (expires_at > created_at AND expires_at <= created_at + INTERVAL '60 minutes')
);

CREATE TABLE audit_events (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    schema_version SMALLINT NOT NULL DEFAULT 1,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    request_id TEXT NOT NULL,
    actor_kind TEXT NOT NULL CHECK (actor_kind IN ('USER', 'SERVICE', 'ANONYMOUS')),
    actor_id TEXT,
    actor_role TEXT,
    source_ip INET,
    user_agent VARCHAR(256),
    session_reference TEXT,
    support_grant_id TEXT,
    site_id BIGINT,
    unit_id BIGINT,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    outcome TEXT NOT NULL CHECK (outcome IN ('SUCCESS', 'DENIED', 'FAILURE')),
    policy_version TEXT NOT NULL DEFAULT 'SPEC-008-v1',
    changes JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_events_site_time ON audit_events(site_id, event_id DESC);
CREATE INDEX audit_events_actor_time ON audit_events(actor_id, event_id DESC);
CREATE INDEX audit_events_request ON audit_events(request_id);

CREATE FUNCTION sp_audit_immutable() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Audit evidence is append-only' USING ERRCODE = '42501';
END $$;
CREATE TRIGGER audit_events_no_update_delete BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION sp_audit_immutable();
CREATE TRIGGER audit_events_no_truncate BEFORE TRUNCATE ON audit_events
    FOR EACH STATEMENT EXECUTE FUNCTION sp_audit_immutable();
REVOKE ALL ON audit_events FROM PUBLIC;

-- Explicit allowlist: passwords, hashes, tokens, personal contact details, banking
-- secrets and complete entity snapshots never enter the audit payload.
CREATE FUNCTION sp_audit_projection(value JSONB) RETURNS JSONB LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(jsonb_object_agg(key, CASE WHEN key = ANY(ARRAY['amount','principal_amount','delay_penalty','paid_principal','paid_penalty','allocated_advance','total_amount','total_budget','annual_amount','monthly_amount','rate_percent']) THEN to_jsonb(val #>> '{}') ELSE val END), '{}'::jsonb)
    FROM jsonb_each(value) AS fields(key, val)
    WHERE key = ANY(ARRAY['amount','principal_amount','delay_penalty','paid_principal','paid_penalty','allocated_advance','total_amount','total_budget','annual_amount','monthly_amount','rate_percent','status','role','is_active','must_change_password',
        'site_id','unit_id','owner_person_id','tenant_person_id','person_id',
        'debtor_type','payer_role','receipt_type','reverses_receipt_id',
        'settlement_status','matched_unit_id','auth_version','revoked_at',
        'approved_by','operator_user_id','expires_at','permissions','user_id','currency','auth_provider','budget_id','operating_budget_id','fiscal_year','year','allocation_basis'])
$$;
CREATE FUNCTION sp_audit_domain_change() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    before_value JSONB := CASE WHEN TG_OP = 'INSERT' THEN '{}'::jsonb ELSE to_jsonb(OLD) END;
    after_value JSONB := CASE WHEN TG_OP = 'DELETE' THEN '{}'::jsonb ELSE to_jsonb(NEW) END;
    value JSONB;
    context JSONB;
    tenant BIGINT;
    unit BIGINT;
    event_action TEXT;
BEGIN
    value := CASE WHEN TG_OP = 'DELETE' THEN before_value ELSE after_value END;
    context := COALESCE(NULLIF(current_setting('sitepulse.audit_context', true), ''), '{}')::jsonb;
    tenant := NULLIF(value->>'site_id','')::bigint;
    unit := NULLIF(value->>'unit_id','')::bigint;
    IF TG_TABLE_NAME = 'sites' THEN tenant := (value->>'id')::bigint; END IF;
    IF TG_TABLE_NAME = 'units' THEN unit := (value->>'id')::bigint; END IF;
    IF unit IS NULL AND value->>'occupancy_id' IS NOT NULL THEN
        SELECT unit_id INTO unit FROM unit_occupancies WHERE id=(value->>'occupancy_id')::bigint;
    END IF;
    IF unit IS NULL AND value->>'payment_entry_id' IS NOT NULL THEN
        SELECT site_id,unit_id INTO tenant,unit FROM payment_entries WHERE id=(value->>'payment_entry_id')::bigint;
    END IF;
    IF tenant IS NULL AND value->>'project_id' IS NOT NULL THEN
        SELECT site_id INTO tenant FROM capital_projects WHERE id=(value->>'project_id')::bigint;
    END IF;
    IF tenant IS NULL AND value->>'budget_id' IS NOT NULL THEN
        SELECT site_id INTO tenant FROM operating_budgets WHERE id=(value->>'budget_id')::bigint;
    END IF;
    IF tenant IS NULL AND unit IS NOT NULL THEN
        SELECT site_id INTO tenant FROM units WHERE id = unit;
    END IF;
    IF context->>'actor_kind'='SERVICE' AND context->>'actor_id'='bank-webhook'
       AND TG_TABLE_NAME NOT IN ('payment_entries','payment_receipts','payment_allocations','advance_ledger_entries','dues_liabilities','reconciliation_queue','processed_bank_webhooks','unit_sender_ibans','unit_payer_names') THEN
        RAISE EXCEPTION 'Webhook identity cannot perform this action' USING ERRCODE='42501';
    END IF;
    IF context->>'actor_kind'='SERVICE' AND context->>'actor_id'='payment-provider'
       AND TG_TABLE_NAME NOT IN ('payment_intents','payment_entries','payment_receipts','payment_allocations','advance_ledger_entries','dues_liabilities','reconciliation_queue','processed_bank_webhooks','unit_sender_ibans','unit_payer_names') THEN
        RAISE EXCEPTION 'Provider identity cannot perform this action' USING ERRCODE='42501';
    END IF;
    IF context->>'actor_kind'='SERVICE' AND context->>'actor_id'='dues-scheduler'
       AND TG_TABLE_NAME NOT IN ('dues_liabilities','dues_periods','advance_ledger_entries') THEN
        RAISE EXCEPTION 'Scheduler identity cannot perform this action' USING ERRCODE='42501';
    END IF;
    IF context->>'actor_kind' = 'USER' AND TG_TABLE_NAME <> 'auth_sessions' THEN
        PERFORM actor.id FROM users actor JOIN auth_sessions session ON session.user_id=actor.id
        WHERE actor.id::text=context->>'actor_id' AND actor.is_active
          AND actor.role=context->>'actor_role' AND session.id=context->>'session_id'
          AND session.revoked_at IS NULL AND session.expires_at>clock_timestamp()
          AND (actor.auth_version=session.auth_version OR
               (TG_TABLE_NAME='users' AND before_value->>'id'=context->>'actor_id'
                AND (before_value->>'auth_version')::bigint=session.auth_version))
        FOR SHARE OF actor,session;
        IF NOT FOUND THEN RAISE EXCEPTION 'Session no longer authorized' USING ERRCODE='42501'; END IF;
        IF unit IS NOT NULL AND context->>'actor_role' IN ('HOME_OWNER','HOME_RESIDENT') THEN
            PERFORM u.id FROM units u JOIN users actor ON actor.id::text=context->>'actor_id'
            WHERE u.id=unit AND (u.owner_person_id=actor.person_id OR
                (TG_TABLE_NAME NOT IN ('occupancy_members','invitation_tokens') AND
                  (u.tenant_person_id=actor.person_id OR EXISTS(
                    SELECT 1 FROM occupancy_members m JOIN unit_occupancies o ON o.id=m.occupancy_id
                    WHERE o.unit_id=u.id AND o.is_active AND o.end_date IS NULL AND m.person_id=actor.person_id))))
            FOR SHARE OF u;
            IF NOT FOUND THEN RAISE EXCEPTION 'Unit relationship no longer authorized' USING ERRCODE='42501'; END IF;
        END IF;
        IF tenant IS NOT NULL AND context->>'platform' IS DISTINCT FROM 'true' AND context->>'development' IS DISTINCT FROM 'true' THEN
            PERFORM id FROM sites WHERE id=tenant AND status IN ('ACTIVE','TRIAL') AND deleted_at IS NULL FOR SHARE;
            IF NOT FOUND THEN RAISE EXCEPTION 'Site no longer active' USING ERRCODE='42501'; END IF;
            IF context->>'actor_role'='SAAS_ADMIN' THEN
                PERFORM id FROM support_grants WHERE id=context->>'support_grant_id'
                  AND operator_user_id::text=context->>'actor_id' AND site_id=tenant
                  AND approved_by IS NOT NULL AND approved_by<>operator_user_id
                  AND revoked_at IS NULL AND expires_at>clock_timestamp() FOR SHARE;
                IF NOT FOUND THEN RAISE EXCEPTION 'Support grant no longer authorized' USING ERRCODE='42501'; END IF;
            END IF;
        END IF;
    END IF;
    IF context->>'actor_kind' = 'USER' AND tenant IS NOT NULL
       AND context->>'site_id' IS DISTINCT FROM tenant::text
       AND NOT (context->>'platform' = 'true' AND TG_TABLE_NAME IN ('sites','users','user_site_roles','auth_sessions','support_grants'))
       AND context->>'development' IS DISTINCT FROM 'true' THEN
        RAISE EXCEPTION 'Resource outside authorized tenant' USING ERRCODE = '42501';
    END IF;
    event_action := CASE
        WHEN TG_TABLE_NAME='pending_registrations' AND after_value->>'status'='APPROVED' THEN 'REGISTRATION_APPROVED'
        WHEN TG_TABLE_NAME='pending_registrations' AND after_value->>'status'='REJECTED' THEN 'REGISTRATION_REJECTED'
        WHEN TG_TABLE_NAME='users' AND TG_OP='UPDATE' AND before_value->>'password_hash' IS DISTINCT FROM after_value->>'password_hash'
            THEN CASE WHEN value->>'id'=context->>'actor_id' THEN 'AUTH_PASSWORD_CHANGED' ELSE 'AUTH_PASSWORD_RESET_BY_ADMIN' END
        WHEN TG_TABLE_NAME='users' AND TG_OP='UPDATE' AND before_value->>'role' IS DISTINCT FROM after_value->>'role' THEN 'ROLE_GRANTED'
        WHEN TG_TABLE_NAME='auth_sessions' AND after_value->>'revoked_at' IS NOT NULL THEN 'AUTH_SESSION_REVOKED'
        WHEN TG_TABLE_NAME='auth_sessions' AND TG_OP='INSERT' THEN 'AUTH_SESSION_CREATED'
        WHEN TG_TABLE_NAME='payment_receipts' AND after_value->>'receipt_type'='REVERSAL' THEN 'PAYMENT_REVERSED'
        WHEN TG_TABLE_NAME='payment_receipts' AND after_value->>'payment_channel'='INTER_LEDGER' THEN 'LEDGER_TRANSFER'
        WHEN TG_TABLE_NAME='payment_receipts' AND after_value->>'payment_channel' LIKE 'MANUAL_%' THEN 'PAYMENT_RECORDED_MANUAL'
        WHEN TG_TABLE_NAME='payment_receipts' THEN 'PAYMENT_RECORDED'
        WHEN TG_TABLE_NAME='site_bank_accounts' THEN 'BANK_ACCOUNT_CHANGED'
        WHEN TG_TABLE_NAME='sites' AND TG_OP='INSERT' THEN 'SITE_CREATED'
        WHEN TG_TABLE_NAME='sites' AND after_value->>'status'='SUSPENDED' THEN 'SITE_SUSPENDED'
        WHEN TG_TABLE_NAME='support_grants' AND TG_OP='INSERT' THEN 'SUPPORT_GRANT_CREATED'
        WHEN TG_TABLE_NAME='support_grants' AND after_value->>'revoked_at' IS NOT NULL THEN 'SUPPORT_GRANT_REVOKED'
        WHEN TG_TABLE_NAME='support_grants' THEN 'SUPPORT_GRANT_APPROVED'
        WHEN TG_TABLE_NAME='units' AND TG_OP='UPDATE' AND before_value->>'owner_person_id' IS DISTINCT FROM after_value->>'owner_person_id' THEN 'UNIT_OWNERSHIP_TRANSFERRED'
        WHEN TG_TABLE_NAME='unit_occupancies' AND TG_OP='INSERT' THEN 'UNIT_MOVE_IN'
        WHEN TG_TABLE_NAME='unit_occupancies' AND after_value->>'end_date' IS NOT NULL THEN 'UNIT_MOVE_OUT'
        ELSE TG_TABLE_NAME || '.' || TG_OP END;
    INSERT INTO audit_events(request_id,actor_kind,actor_id,actor_role,session_reference,support_grant_id,source_ip,user_agent,
        site_id,unit_id,action,resource_type,resource_id,outcome,changes)
    VALUES (COALESCE(context->>'request_id','database'), COALESCE(context->>'actor_kind','SERVICE'),
        COALESCE(context->>'actor_id',current_user),context->>'actor_role',context->>'session_id',context->>'support_grant_id',NULLIF(context->>'source_ip','')::inet,left(context->>'user_agent',256),
        CASE WHEN context->>'platform'='true' THEN NULL ELSE tenant END,unit,event_action,TG_TABLE_NAME,
        COALESCE(value->>'id',value->>'request_id'), 'SUCCESS',
        jsonb_build_object('before',sp_audit_projection(before_value),'after',sp_audit_projection(after_value)));
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

DO $$
DECLARE name TEXT;
BEGIN
    FOREACH name IN ARRAY ARRAY['sites','users','units','pending_registrations',
        'unit_ownerships','unit_occupancies','occupancy_members','user_site_roles',
        'payment_entries','payment_receipts','payment_allocations','advance_ledger_entries',
        'dues_liabilities','dues_periods','site_bank_accounts','reconciliation_queue',
        'capital_projects','capital_project_installments','capital_contractor_disbursements',
        'payment_intents','operating_budgets','operating_budget_lines','operating_budget_unit_shares',
        'budget_service_records','budget_objections','revaluation_rates',
        'auth_sessions','support_grants','invitation_tokens','processed_bank_webhooks','unit_sender_ibans','unit_payer_names']
    LOOP
        IF to_regclass('public.' || name) IS NOT NULL THEN
            EXECUTE format('CREATE TRIGGER audit_domain_change AFTER INSERT OR UPDATE OR DELETE ON %I FOR EACH ROW EXECUTE FUNCTION sp_audit_domain_change()',name);
        END IF;
    END LOOP;
END $$;

CREATE FUNCTION sp_invalidate_user_credentials() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF (NEW.password_hash,NEW.role,NEW.site_id,NEW.is_active,NEW.google_sub)
        IS DISTINCT FROM (OLD.password_hash,OLD.role,OLD.site_id,OLD.is_active,OLD.google_sub) THEN
        NEW.auth_version := OLD.auth_version + 1;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER invalidate_user_credentials BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION sp_invalidate_user_credentials();

-- RLS applies to non-owner runtime readers; production deployments must use a
-- non-owner, non-superuser role. Table owners and superusers remain privileged.
ALTER TABLE audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events FORCE ROW LEVEL SECURITY;
CREATE POLICY audit_events_insert ON audit_events FOR INSERT WITH CHECK (true);
CREATE POLICY audit_events_select ON audit_events FOR SELECT USING (
    (COALESCE(NULLIF(current_setting('sitepulse.audit_context',true),'')::jsonb -> 'permissions','[]'::jsonb)
        ?| ARRAY['AUDIT_LOG_READ','AUDIT_LOG_EXPORT'])
    AND (site_id::text = (NULLIF(current_setting('sitepulse.audit_context',true),'')::jsonb ->> 'site_id')
    OR (site_id IS NULL AND NULLIF(current_setting('sitepulse.audit_context',true),'')::jsonb ->> 'actor_role' = 'SAAS_ADMIN'))
);
