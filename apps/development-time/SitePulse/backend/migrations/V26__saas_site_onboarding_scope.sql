-- V26: SaaS platform admin scope for site onboarding.
--
-- When a SaaS administrator onboards a site, the manager's person record, the
-- site's initial blocks and the manager's activation token are created in the
-- new tenant's scope. Allow `platform = true` contexts to write them.

CREATE OR REPLACE FUNCTION sp_audit_domain_change() RETURNS trigger LANGUAGE plpgsql AS $$
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
       AND NOT (context->>'platform' = 'true' AND TG_TABLE_NAME IN ('sites','users','user_site_roles','auth_sessions','support_grants','blocks','persons','account_activations'))
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
