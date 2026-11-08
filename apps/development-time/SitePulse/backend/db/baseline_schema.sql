--
-- PostgreSQL database dump
--

\restrict 5qygkS6aN39jOHS0yYpboxyymbkW8pK9Z7c0BSQWgypSlTeBtD7eEt04QFScxsX

-- Dumped from database version 16.15
-- Dumped by pg_dump version 16.15

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

-- *not* creating schema, since initdb creates it


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS '';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: sp_add_constraint(regclass, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_add_constraint(p_table regclass, p_name text, p_definition text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = p_table AND conname = p_name) THEN
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I %s NOT VALID', p_table, p_name, p_definition);
    END IF;
    PERFORM sp_try_validate(p_table, p_name);
END;
$$;


--
-- Name: sp_ledger_append_only(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_ledger_append_only() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF current_setting('sitepulse.allow_ledger_purge', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    RAISE EXCEPTION '% rows are append-only (% rejected)', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'integrity_constraint_violation';
END;
$$;


--
-- Name: sp_payment_entry_guard(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_payment_entry_guard() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF current_setting('sitepulse.allow_ledger_purge', true) = 'on' THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'payment_entries rows are append-only (DELETE rejected)'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.site_id IS DISTINCT FROM OLD.site_id
       OR NEW.unit_id IS DISTINCT FROM OLD.unit_id
       OR NEW.payment_channel IS DISTINCT FROM OLD.payment_channel
       OR NEW.payment_date IS DISTINCT FROM OLD.payment_date
       OR NEW.external_reference IS DISTINCT FROM OLD.external_reference
       OR NEW.created_at IS DISTINCT FROM OLD.created_at
       OR NEW.entry_type IS DISTINCT FROM OLD.entry_type
       OR NEW.reverses_entry_id IS DISTINCT FROM OLD.reverses_entry_id
       OR NEW.reversal_reason IS DISTINCT FROM OLD.reversal_reason
       OR NEW.recorded_by IS DISTINCT FROM OLD.recorded_by
       OR (OLD.payer_person_id IS NOT NULL AND NEW.payer_person_id IS DISTINCT FROM OLD.payer_person_id)
       OR (OLD.occupancy_id IS NOT NULL AND NEW.occupancy_id IS DISTINCT FROM OLD.occupancy_id) THEN
        RAISE EXCEPTION 'payment_entries %: financial columns are immutable', OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.settlement_status IS DISTINCT FROM OLD.settlement_status THEN
        IF NOT ((OLD.settlement_status IN ('UNMATCHED', 'PENDING') AND NEW.settlement_status = 'SETTLED'
                 AND OLD.receipt_id IS NULL AND NEW.receipt_id IS NOT NULL)
                OR (OLD.settlement_status = 'SETTLED' AND NEW.settlement_status = 'REVERSED'
                    AND OLD.entry_type = 'COLLECTION'
                    AND EXISTS (SELECT 1 FROM payment_entries x WHERE x.reverses_entry_id = OLD.id))) THEN
            RAISE EXCEPTION 'payment_entries %: transition % -> % is not allowed',
                OLD.id, OLD.settlement_status, NEW.settlement_status
                USING ERRCODE = 'integrity_constraint_violation';
        END IF;
    ELSIF NEW.receipt_id IS DISTINCT FROM OLD.receipt_id THEN
        RAISE EXCEPTION 'payment_entries %: receipt_id changes only with UNMATCHED -> SETTLED', OLD.id
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    RETURN NEW;
END;
$$;


--
-- Name: sp_protect_national_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_protect_national_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.national_id IS NOT NULL AND NEW.national_id <> '' THEN
        NEW.national_id_hash := encode(hmac(convert_to(NEW.national_id, 'UTF8'), (SELECT hmac_key FROM pii_settings), 'sha256'), 'hex');
        NEW.national_id_masked := repeat('*', GREATEST(length(NEW.national_id) - 4, 0)) || right(NEW.national_id, 4);
    END IF;
    NEW.national_id := NULL;
    RETURN NEW;
END;
$$;


--
-- Name: sp_set_fk(regclass, text, regclass, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_set_fk(p_table regclass, p_column text, p_ref regclass, p_name text, p_rule text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE r record;
BEGIN
    FOR r IN
        SELECT c.conname FROM pg_constraint c
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
        WHERE c.contype = 'f' AND c.conrelid = p_table AND a.attname = p_column AND array_length(c.conkey, 1) = 1
    LOOP
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', p_table, r.conname);
    END LOOP;
    EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %s(id) ON DELETE %s NOT VALID',
                   p_table, p_name, p_column, p_ref, p_rule);
    PERFORM sp_try_validate(p_table, p_name);
END;
$$;


--
-- Name: sp_sync_unit_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sync_unit_owner() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE target BIGINT := COALESCE(NEW.unit_id, OLD.unit_id);
BEGIN
    UPDATE units u
    SET owner_person_id = (
        SELECT o.person_id FROM unit_ownerships o
        WHERE o.unit_id = target AND o.is_active
        ORDER BY o.share_percentage DESC, o.start_date DESC, o.id DESC LIMIT 1)
    WHERE u.id = target
      AND EXISTS (SELECT 1 FROM unit_ownerships o WHERE o.unit_id = target);
    RETURN NULL;
END;
$$;


--
-- Name: sp_sync_unit_tenant(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_sync_unit_tenant() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE target BIGINT := COALESCE(NEW.unit_id, OLD.unit_id);
BEGIN
    UPDATE units u
    SET tenant_person_id = (
        SELECT oc.person_id FROM unit_occupancies oc
        WHERE oc.unit_id = target AND oc.is_active AND oc.occupancy_type = 'TENANT'
        ORDER BY oc.start_date DESC, oc.id DESC LIMIT 1)
    WHERE u.id = target;
    RETURN NULL;
END;
$$;


--
-- Name: sp_try_validate(regclass, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_try_validate(p_table regclass, p_constraint text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    EXECUTE format('ALTER TABLE %s VALIDATE CONSTRAINT %I', p_table, p_constraint);
EXCEPTION WHEN others THEN
    RAISE WARNING 'Constraint % on % left NOT VALID (existing rows violate it): %', p_constraint, p_table, SQLERRM;
END;
$$;


--
-- Name: sp_unit_party_at(bigint, text, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.sp_unit_party_at(p_unit bigint, p_role text, p_at date) RETURNS TABLE(person_id bigint, occupancy_id bigint)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    IF p_role = 'OWNER' THEN
        RETURN QUERY
        SELECT o.person_id, oc.id
        FROM unit_ownerships o
        LEFT JOIN unit_occupancies oc
               ON oc.unit_id = o.unit_id AND oc.person_id = o.person_id AND oc.occupancy_type = 'OWNER'
              AND oc.start_date <= p_at AND (oc.end_date IS NULL OR oc.end_date >= p_at)
        WHERE o.unit_id = p_unit AND o.start_date <= p_at AND (o.end_date IS NULL OR o.end_date >= p_at)
        ORDER BY o.share_percentage DESC, o.start_date DESC, o.id DESC
        LIMIT 1;
        IF NOT FOUND THEN
            -- No ownership history (pre-V7 data or direct seeds): the unit's owner column.
            RETURN QUERY SELECT u.owner_person_id, NULL::BIGINT FROM units u
                         WHERE u.id = p_unit AND u.owner_person_id IS NOT NULL;
        END IF;
    ELSE
        RETURN QUERY
        SELECT oc.person_id, oc.id
        FROM unit_occupancies oc
        WHERE oc.unit_id = p_unit AND oc.occupancy_type = 'TENANT'
          AND oc.start_date <= p_at AND (oc.end_date IS NULL OR oc.end_date >= p_at)
        ORDER BY oc.start_date DESC, oc.id DESC
        LIMIT 1;
        IF NOT FOUND THEN
            RETURN QUERY SELECT u.tenant_person_id, NULL::BIGINT FROM units u
                         WHERE u.id = p_unit AND u.tenant_person_id IS NOT NULL;
        END IF;
    END IF;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: advance_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.advance_balances (
    unit_id bigint NOT NULL,
    balance numeric(15,2) DEFAULT 0.00 NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    debtor_type character varying(20) DEFAULT 'TENANT'::character varying NOT NULL,
    CONSTRAINT chk_advance_balance_non_negative CHECK ((balance >= (0)::numeric)),
    CONSTRAINT chk_advance_debtor_type CHECK (((debtor_type)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[])))
);


--
-- Name: advance_ledger_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.advance_ledger_entries (
    id bigint NOT NULL,
    unit_id bigint NOT NULL,
    debtor_type character varying(20) NOT NULL,
    entry_type character varying(30) NOT NULL,
    amount numeric(15,2) NOT NULL,
    reference_id character varying(100),
    description text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT advance_ledger_entries_debtor_type_check CHECK (((debtor_type)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[]))),
    CONSTRAINT chk_advance_ledger_amount_positive CHECK ((amount > (0)::numeric)),
    CONSTRAINT chk_advance_ledger_entry_type CHECK (((entry_type)::text = ANY ((ARRAY['PAYMENT_SURPLUS'::character varying, 'OFFSET_APPLIED'::character varying, 'VIRMAN_DEBIT'::character varying, 'REFUND'::character varying, 'ADJUSTMENT'::character varying, 'ADJUSTMENT_CREDIT'::character varying, 'ADJUSTMENT_DEBIT'::character varying, 'VIRMAN_REVERSAL'::character varying])::text[])))
);


--
-- Name: advance_ledger_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.advance_ledger_entries ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.advance_ledger_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.blocks (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    block_name character varying(50) NOT NULL,
    total_floors integer DEFAULT 1 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: blocks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.blocks ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.blocks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: budget_objections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.budget_objections (
    id bigint NOT NULL,
    budget_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    objector_name text NOT NULL,
    filed_on date NOT NULL,
    reason text NOT NULL,
    status character varying(20) DEFAULT 'OPEN'::character varying NOT NULL,
    resolved_on date,
    resolution_note text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT budget_objections_reason_check CHECK ((length(TRIM(BOTH FROM reason)) >= 3)),
    CONSTRAINT chk_budget_objections_resolution CHECK ((((status)::text = 'OPEN'::text) = (resolved_on IS NULL))),
    CONSTRAINT chk_budget_objections_status CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'UPHELD'::character varying, 'DISMISSED'::character varying])::text[])))
);


--
-- Name: budget_objections_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.budget_objections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: budget_objections_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.budget_objections_id_seq OWNED BY public.budget_objections.id;


--
-- Name: budget_service_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.budget_service_records (
    id bigint NOT NULL,
    budget_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    recipient_name text NOT NULL,
    method character varying(20) NOT NULL,
    served_on date NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_budget_service_method CHECK (((method)::text = ANY ((ARRAY['IN_ASSEMBLY'::character varying, 'SIGNATURE'::character varying, 'REGISTERED_MAIL'::character varying, 'E_NOTIFICATION'::character varying])::text[])))
);


--
-- Name: budget_service_records_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.budget_service_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: budget_service_records_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.budget_service_records_id_seq OWNED BY public.budget_service_records.id;


--
-- Name: capital_contractor_disbursements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capital_contractor_disbursements (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    milestone_name character varying(120) NOT NULL,
    invoice_number character varying(60),
    amount numeric(15,2) NOT NULL,
    disbursement_date date DEFAULT CURRENT_DATE NOT NULL,
    recipient_name character varying(150) NOT NULL,
    recipient_iban character varying(34) NOT NULL,
    payment_reference character varying(100),
    disbursement_method character varying(30) DEFAULT 'BANK_TRANSFER'::character varying NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_disbursement_amount_positive CHECK ((amount > (0)::numeric))
);


--
-- Name: capital_contractor_disbursements_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.capital_contractor_disbursements ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.capital_contractor_disbursements_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: capital_project_installments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capital_project_installments (
    id bigint NOT NULL,
    project_id bigint NOT NULL,
    installment_number integer NOT NULL,
    total_installments integer NOT NULL,
    due_date date NOT NULL,
    installment_budget numeric(15,2) NOT NULL,
    percentage numeric(5,2) NOT NULL,
    is_accrued boolean DEFAULT false NOT NULL,
    accrued_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_installment_budget_positive CHECK ((installment_budget > (0)::numeric)),
    CONSTRAINT chk_installment_pct_positive CHECK (((percentage > (0)::numeric) AND (percentage <= 100.00)))
);


--
-- Name: capital_project_installments_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.capital_project_installments ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.capital_project_installments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: capital_projects; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capital_projects (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    title character varying(180) NOT NULL,
    category character varying(40) NOT NULL,
    description text,
    total_budget numeric(15,2) NOT NULL,
    allocation_basis character varying(30) DEFAULT 'BY_LAND_SHARE'::character varying NOT NULL,
    target_start_date date NOT NULL,
    target_completion_date date,
    contractor_name character varying(150),
    contractor_tax_no character varying(20),
    contractor_iban character varying(34),
    contract_amount numeric(15,2),
    status character varying(30) DEFAULT 'ACTIVE'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_capital_budget_positive CHECK ((total_budget > (0)::numeric)),
    CONSTRAINT chk_capital_projects_allocation_basis CHECK (((allocation_basis)::text = ANY ((ARRAY['BY_LAND_SHARE'::character varying, 'EQUAL_PER_UNIT'::character varying])::text[]))),
    CONSTRAINT chk_capital_projects_category CHECK (((category)::text = ANY ((ARRAY['ELEVATOR'::character varying, 'FACADE_INSULATION'::character varying, 'ROOF_WATERPROOFING'::character varying, 'GENERATOR'::character varying, 'SECURITY_SYSTEM'::character varying, 'FIRE_SAFETY'::character varying, 'OTHER'::character varying])::text[]))),
    CONSTRAINT chk_capital_projects_status CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'PLANNED'::character varying, 'ACTIVE'::character varying, 'ON_HOLD'::character varying, 'COMPLETED'::character varying, 'CANCELLED'::character varying])::text[])))
);


--
-- Name: capital_projects_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.capital_projects ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.capital_projects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: debt_aging_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.debt_aging_snapshots (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    debtor_type character varying(20) NOT NULL,
    current_due numeric(15,2) DEFAULT 0.00 NOT NULL,
    overdue_1_30_days numeric(15,2) DEFAULT 0.00 NOT NULL,
    overdue_31_60_days numeric(15,2) DEFAULT 0.00 NOT NULL,
    overdue_60_plus_days numeric(15,2) DEFAULT 0.00 NOT NULL,
    accrued_delay_penalty numeric(15,2) DEFAULT 0.00 NOT NULL,
    total_outstanding numeric(15,2) DEFAULT 0.00 NOT NULL,
    as_of_date date DEFAULT CURRENT_DATE NOT NULL
);


--
-- Name: debt_aging_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.debt_aging_snapshots ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.debt_aging_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dues_liabilities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dues_liabilities (
    id bigint NOT NULL,
    unit_id bigint NOT NULL,
    period character varying(50) NOT NULL,
    debtor_type character varying(20) DEFAULT 'TENANT'::character varying NOT NULL,
    expense_type character varying(30) DEFAULT 'OPERATIONAL_DUES'::character varying NOT NULL,
    liable_person_id bigint,
    occupancy_id bigint,
    principal_amount numeric(15,2) NOT NULL,
    due_date date NOT NULL,
    status character varying(20) DEFAULT 'PENDING'::character varying NOT NULL,
    delay_penalty numeric(15,2) DEFAULT 0.00 NOT NULL,
    paid_amount numeric(15,2) DEFAULT 0.00 NOT NULL,
    payment_date timestamp with time zone,
    version integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    capital_project_id bigint,
    installment_number integer,
    paid_principal numeric(15,2) DEFAULT 0.00 NOT NULL,
    paid_penalty numeric(15,2) DEFAULT 0.00 NOT NULL,
    dues_period_id bigint,
    capital_project_installment_id bigint,
    penalty_accrued_through date,
    operating_budget_id bigint,
    CONSTRAINT chk_dues_capital_owner_only CHECK ((((expense_type)::text <> 'CAPITAL_DUES'::text) OR ((debtor_type)::text = 'OWNER'::text))),
    CONSTRAINT chk_dues_debtor_type CHECK (((debtor_type)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[]))),
    CONSTRAINT chk_dues_expense_type CHECK (((expense_type)::text = ANY ((ARRAY['OPERATIONAL_DUES'::character varying, 'CAPITAL_DUES'::character varying])::text[]))),
    CONSTRAINT chk_dues_paid_components CHECK ((paid_amount = (paid_principal + paid_penalty))),
    CONSTRAINT chk_dues_paid_non_negative CHECK ((paid_amount >= (0)::numeric)),
    CONSTRAINT chk_dues_paid_penalty_within CHECK (((paid_penalty >= (0)::numeric) AND (paid_penalty <= delay_penalty))),
    CONSTRAINT chk_dues_paid_principal_within CHECK (((paid_principal >= (0)::numeric) AND (paid_principal <= principal_amount))),
    CONSTRAINT chk_dues_paid_status_consistent CHECK ((((status)::text = 'CANCELLED'::text) OR ((((status)::text = 'PAID'::text) = ((paid_principal >= principal_amount) AND (paid_penalty >= delay_penalty))) AND (((status)::text <> 'PARTIALLY_PAID'::text) OR (paid_amount > (0)::numeric))))),
    CONSTRAINT chk_dues_paid_within_owed CHECK ((paid_amount <= (principal_amount + delay_penalty))),
    CONSTRAINT chk_dues_penalty_accrued_after_due CHECK (((penalty_accrued_through IS NULL) OR (penalty_accrued_through >= due_date))),
    CONSTRAINT chk_dues_penalty_non_negative CHECK ((delay_penalty >= (0)::numeric)),
    CONSTRAINT chk_dues_principal_non_negative CHECK ((principal_amount >= (0)::numeric)),
    CONSTRAINT chk_dues_status CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'PAID'::character varying, 'OVERDUE'::character varying, 'CANCELLED'::character varying, 'PARTIALLY_PAID'::character varying])::text[])))
);


--
-- Name: dues_liabilities_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.dues_liabilities ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.dues_liabilities_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dues_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dues_periods (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    period_name character varying(50) NOT NULL,
    due_date date NOT NULL,
    status character varying(20) DEFAULT 'ACTIVE'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_dues_periods_status CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'OPEN'::character varying, 'ACTIVE'::character varying, 'ACCRUED'::character varying, 'CLOSED'::character varying])::text[])))
);


--
-- Name: dues_periods_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.dues_periods ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.dues_periods_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: house_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.house_types (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    type_name character varying(50) NOT NULL,
    dues_amount numeric(15,2) NOT NULL,
    description character varying(200),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: house_types_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.house_types ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.house_types_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: invitation_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invitation_tokens (
    token character varying(100) NOT NULL,
    token_type character varying(20) DEFAULT 'UNIT'::character varying NOT NULL,
    site_id bigint,
    unit_id bigint,
    building character varying(50),
    unit_number character varying(20),
    relationship character varying(100),
    invite_url text NOT NULL,
    security_notice text,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: occupancy_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.occupancy_members (
    id bigint NOT NULL,
    occupancy_id bigint NOT NULL,
    person_id bigint,
    full_name character varying(120) NOT NULL,
    relationship character varying(50) NOT NULL,
    phone character varying(30),
    email character varying(120),
    is_emergency_contact boolean DEFAULT false NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    resident_user_id bigint
);


--
-- Name: occupancy_members_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.occupancy_members ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.occupancy_members_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: operating_budget_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operating_budget_lines (
    id bigint NOT NULL,
    budget_id bigint NOT NULL,
    category character varying(30) NOT NULL,
    description text,
    annual_amount numeric(15,2) NOT NULL,
    allocation_key character varying(20) DEFAULT 'LAND_SHARE'::character varying NOT NULL,
    CONSTRAINT chk_operating_budget_lines_category CHECK (((category)::text = ANY ((ARRAY['PERSONNEL'::character varying, 'CLEANING'::character varying, 'ENERGY'::character varying, 'WATER'::character varying, 'MAINTENANCE'::character varying, 'INSURANCE'::character varying, 'MANAGEMENT_FEE'::character varying, 'SECURITY'::character varying, 'GARDENING'::character varying, 'RESERVE'::character varying, 'OTHER'::character varying])::text[]))),
    CONSTRAINT chk_operating_budget_lines_key CHECK (((allocation_key)::text = ANY ((ARRAY['LAND_SHARE'::character varying, 'EQUAL'::character varying])::text[]))),
    CONSTRAINT operating_budget_lines_annual_amount_check CHECK ((annual_amount > (0)::numeric))
);


--
-- Name: operating_budget_lines_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.operating_budget_lines_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: operating_budget_lines_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.operating_budget_lines_id_seq OWNED BY public.operating_budget_lines.id;


--
-- Name: operating_budget_unit_shares; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operating_budget_unit_shares (
    budget_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    land_share integer NOT NULL,
    annual_amount numeric(15,2) NOT NULL,
    monthly_amount numeric(15,2) NOT NULL,
    CONSTRAINT operating_budget_unit_shares_annual_amount_check CHECK ((annual_amount >= (0)::numeric)),
    CONSTRAINT operating_budget_unit_shares_land_share_check CHECK ((land_share > 0)),
    CONSTRAINT operating_budget_unit_shares_monthly_amount_check CHECK ((monthly_amount >= (0)::numeric))
);


--
-- Name: operating_budgets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.operating_budgets (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    fiscal_year integer NOT NULL,
    period_start date NOT NULL,
    period_end date NOT NULL,
    status character varying(20) DEFAULT 'DRAFT'::character varying NOT NULL,
    previous_budget_id bigint,
    baseline_annual_amount numeric(15,2) DEFAULT 0 NOT NULL,
    total_annual_amount numeric(15,2) DEFAULT 0 NOT NULL,
    increase_rate numeric(9,4),
    cap_rate numeric(7,4),
    assembly_decision_ref text,
    assembly_decision_date date,
    interim_issued_on date,
    interim_deadline date,
    objection_deadline date,
    notes text,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_operating_budgets_decision CHECK ((((status)::text <> ALL ((ARRAY['APPROVED'::character varying, 'FINAL'::character varying])::text[])) OR ((assembly_decision_ref IS NOT NULL) AND (assembly_decision_date IS NOT NULL)))),
    CONSTRAINT chk_operating_budgets_interim CHECK ((((status)::text <> 'INTERIM'::text) OR ((interim_issued_on IS NOT NULL) AND (interim_deadline IS NOT NULL)))),
    CONSTRAINT chk_operating_budgets_period CHECK ((period_end >= period_start)),
    CONSTRAINT chk_operating_budgets_status CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'INTERIM'::character varying, 'APPROVED'::character varying, 'FINAL'::character varying, 'REJECTED'::character varying, 'SUPERSEDED'::character varying])::text[]))),
    CONSTRAINT operating_budgets_baseline_annual_amount_check CHECK ((baseline_annual_amount >= (0)::numeric)),
    CONSTRAINT operating_budgets_fiscal_year_check CHECK (((fiscal_year >= 2000) AND (fiscal_year <= 2100))),
    CONSTRAINT operating_budgets_total_annual_amount_check CHECK ((total_annual_amount >= (0)::numeric))
);


--
-- Name: operating_budgets_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.operating_budgets_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: operating_budgets_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.operating_budgets_id_seq OWNED BY public.operating_budgets.id;


--
-- Name: payment_allocations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_allocations (
    id bigint NOT NULL,
    payment_entry_id bigint NOT NULL,
    dues_liability_id bigint NOT NULL,
    principal_amount numeric(15,2) DEFAULT 0.00 NOT NULL,
    penalty_amount numeric(15,2) DEFAULT 0.00 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_allocation_total_positive CHECK (((principal_amount + penalty_amount) > (0)::numeric)),
    CONSTRAINT payment_allocations_penalty_amount_check CHECK ((penalty_amount >= (0)::numeric)),
    CONSTRAINT payment_allocations_principal_amount_check CHECK ((principal_amount >= (0)::numeric))
);


--
-- Name: payment_allocations_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payment_allocations ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payment_allocations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payment_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_entries (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    payer_name character varying(120) NOT NULL,
    payer_role character varying(20) NOT NULL,
    receipt_id bigint,
    amount numeric(15,2) NOT NULL,
    payment_channel character varying(30) NOT NULL,
    settlement_status character varying(20) DEFAULT 'SETTLED'::character varying NOT NULL,
    description text,
    external_reference character varying(100),
    payment_date timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    payer_person_id bigint,
    occupancy_id bigint,
    legacy_unreceipted boolean DEFAULT false NOT NULL,
    entry_type character varying(20) DEFAULT 'COLLECTION'::character varying NOT NULL,
    reverses_entry_id bigint,
    reversal_reason text,
    recorded_by character varying(255),
    CONSTRAINT chk_payment_entries_channel CHECK (((payment_channel)::text = ANY ((ARRAY['VIRTUAL_IBAN'::character varying, 'BANK_STATEMENT'::character varying, 'BANK_TRANSFER'::character varying, 'CREDIT_CARD'::character varying, 'MANUAL_CASH'::character varying, 'CASH'::character varying, 'INTER_LEDGER'::character varying, 'ONLINE_PAYMENT'::character varying])::text[]))),
    CONSTRAINT chk_payment_entries_entry_type CHECK (((entry_type)::text = ANY ((ARRAY['COLLECTION'::character varying, 'REVERSAL'::character varying])::text[]))),
    CONSTRAINT chk_payment_entries_payer_role CHECK (((payer_role)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[]))),
    CONSTRAINT chk_payment_entries_reversal_shape CHECK (((((entry_type)::text = 'REVERSAL'::text) = (reverses_entry_id IS NOT NULL)) AND (((entry_type)::text <> 'REVERSAL'::text) OR (((settlement_status)::text = 'REVERSED'::text) AND (receipt_id IS NOT NULL) AND (length(btrim(COALESCE(reversal_reason, ''::text))) >= 3) AND (length(btrim((COALESCE(recorded_by, ''::character varying))::text)) > 0))))),
    CONSTRAINT chk_payment_entries_settled_has_receipt CHECK ((((settlement_status)::text <> 'SETTLED'::text) OR (receipt_id IS NOT NULL) OR legacy_unreceipted)),
    CONSTRAINT chk_payment_entries_settlement_status CHECK (((settlement_status)::text = ANY ((ARRAY['SETTLED'::character varying, 'UNMATCHED'::character varying, 'PENDING'::character varying, 'REVERSED'::character varying])::text[]))),
    CONSTRAINT chk_payment_entry_amount CHECK ((amount > (0)::numeric))
);


--
-- Name: payment_entries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payment_entries ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payment_entries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payment_idempotency_keys; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_idempotency_keys (
    site_id bigint NOT NULL,
    idempotency_key character varying(100) NOT NULL,
    receipt_id bigint NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: payment_intents; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_intents (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    debtor_type character varying(10) NOT NULL,
    payer_name text NOT NULL,
    amount numeric(15,2) NOT NULL,
    currency character(3) DEFAULT 'TRY'::bpchar NOT NULL,
    provider character varying(30) NOT NULL,
    provider_ref character varying(100) NOT NULL,
    status character varying(20) DEFAULT 'CREATED'::character varying NOT NULL,
    checkout_url text,
    three_ds_status character varying(20),
    fee_amount numeric(15,2),
    failure_reason text,
    receipt_number character varying(50),
    designation jsonb,
    created_by text NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    captured_at timestamp with time zone,
    CONSTRAINT chk_payment_intents_captured CHECK ((((status)::text <> ALL ((ARRAY['CAPTURED'::character varying, 'REFUNDED'::character varying])::text[])) OR ((receipt_number IS NOT NULL) AND (captured_at IS NOT NULL)))),
    CONSTRAINT chk_payment_intents_debtor CHECK (((debtor_type)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[]))),
    CONSTRAINT chk_payment_intents_status CHECK (((status)::text = ANY ((ARRAY['CREATED'::character varying, 'AUTHORIZED'::character varying, 'CAPTURED'::character varying, 'FAILED'::character varying, 'REFUNDED'::character varying, 'EXPIRED'::character varying])::text[]))),
    CONSTRAINT payment_intents_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payment_intents_fee_amount_check CHECK (((fee_amount IS NULL) OR (fee_amount >= (0)::numeric)))
);


--
-- Name: payment_intents_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payment_intents_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payment_intents_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payment_intents_id_seq OWNED BY public.payment_intents.id;


--
-- Name: payment_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_receipts (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    unit_id bigint NOT NULL,
    receipt_number character varying(30) NOT NULL,
    sequence_number bigint NOT NULL,
    payer_name character varying(120) NOT NULL,
    payer_role character varying(20) NOT NULL,
    on_behalf_of_name character varying(120),
    on_behalf_of_role character varying(20),
    total_amount numeric(15,2) NOT NULL,
    payment_channel character varying(30) NOT NULL,
    channel_reference character varying(100),
    allocated_principal numeric(15,2) DEFAULT 0.00 NOT NULL,
    allocated_penalty numeric(15,2) DEFAULT 0.00 NOT NULL,
    allocated_advance numeric(15,2) DEFAULT 0.00 NOT NULL,
    allocation_breakdown jsonb DEFAULT '[]'::jsonb NOT NULL,
    is_rent_offset_eligible boolean DEFAULT false NOT NULL,
    legal_statutory_note text,
    verification_hash character varying(64) NOT NULL,
    issued_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    payer_person_id bigint,
    on_behalf_of_person_id bigint,
    receipt_type character varying(20) DEFAULT 'COLLECTION'::character varying NOT NULL,
    reverses_receipt_id bigint,
    advance_debtor_type character varying(20),
    issuer_name character varying(150),
    issuer_address text,
    issuer_tax_id character varying(11),
    issuer_tax_office character varying(100),
    CONSTRAINT chk_payment_receipts_advance_debtor CHECK ((((advance_debtor_type IS NULL) OR ((advance_debtor_type)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[]))) AND ((allocated_advance > (0)::numeric) = (advance_debtor_type IS NOT NULL)))),
    CONSTRAINT chk_payment_receipts_channel CHECK (((payment_channel)::text = ANY ((ARRAY['VIRTUAL_IBAN'::character varying, 'BANK_STATEMENT'::character varying, 'BANK_TRANSFER'::character varying, 'CREDIT_CARD'::character varying, 'MANUAL_CASH'::character varying, 'CASH'::character varying, 'INTER_LEDGER'::character varying, 'ONLINE_PAYMENT'::character varying])::text[]))),
    CONSTRAINT chk_payment_receipts_reversal_link CHECK ((((receipt_type)::text = 'REVERSAL'::text) = (reverses_receipt_id IS NOT NULL))),
    CONSTRAINT chk_payment_receipts_type CHECK (((receipt_type)::text = ANY ((ARRAY['COLLECTION'::character varying, 'REVERSAL'::character varying])::text[]))),
    CONSTRAINT chk_receipt_advance_non_negative CHECK ((allocated_advance >= (0)::numeric)),
    CONSTRAINT chk_receipt_allocation_sums CHECK ((((allocated_principal + allocated_penalty) + allocated_advance) = total_amount)),
    CONSTRAINT chk_receipt_penalty_non_negative CHECK ((allocated_penalty >= (0)::numeric)),
    CONSTRAINT chk_receipt_principal_non_negative CHECK ((allocated_principal >= (0)::numeric)),
    CONSTRAINT chk_receipt_total_non_negative CHECK ((total_amount >= (0)::numeric))
);


--
-- Name: payment_receipts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payment_receipts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payment_receipts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pending_registrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_registrations (
    request_id character varying(100) NOT NULL,
    site_id bigint NOT NULL,
    block character varying(50) NOT NULL,
    unit_no integer NOT NULL,
    floor integer NOT NULL,
    full_name character varying(120) NOT NULL,
    email character varying(120) NOT NULL,
    phone character varying(30) NOT NULL,
    is_resident boolean DEFAULT true NOT NULL,
    status character varying(30) DEFAULT 'PENDING'::character varying NOT NULL,
    submitted_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_pending_registrations_status CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'APPROVED'::character varying, 'REJECTED'::character varying])::text[])))
);


--
-- Name: persons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.persons (
    id bigint NOT NULL,
    national_id character varying(11),
    full_name character varying(120) NOT NULL,
    phone character varying(20),
    email character varying(120),
    person_type character varying(20) NOT NULL,
    national_id_hash character varying(64),
    national_id_masked character varying(11),
    CONSTRAINT chk_persons_email_not_blank CHECK (((email IS NULL) OR ((email)::text <> ''::text))),
    CONSTRAINT chk_persons_person_type CHECK (((person_type)::text = ANY ((ARRAY['HOME_OWNER'::character varying, 'HOME_RESIDENT'::character varying, 'SITE_MANAGER'::character varying, 'SAAS_ADMIN'::character varying])::text[])))
);


--
-- Name: persons_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.persons ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.persons_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pii_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pii_settings (
    id boolean DEFAULT true NOT NULL,
    hmac_key bytea NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT pii_settings_id_check CHECK (id)
);


--
-- Name: processed_bank_webhooks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.processed_bank_webhooks (
    transaction_id character varying(100) NOT NULL,
    received_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    id bigint NOT NULL,
    site_id bigint,
    site_bank_account_id bigint,
    receipt_id bigint,
    payload_hash character varying(64),
    scope_key character varying(40) GENERATED ALWAYS AS (COALESCE(('A'::text || (site_bank_account_id)::text), ('S'::text || (site_id)::text), '-'::text)) STORED,
    CONSTRAINT chk_processed_webhooks_payload_hash CHECK (((payload_hash IS NULL) OR ((payload_hash)::text ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT chk_processed_webhooks_scope CHECK (((site_bank_account_id IS NULL) OR (site_id IS NOT NULL)))
);


--
-- Name: processed_bank_webhooks_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.processed_bank_webhooks ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.processed_bank_webhooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: receipt_counters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receipt_counters (
    site_id bigint NOT NULL,
    last_sequence bigint NOT NULL,
    receipt_type character varying(20) DEFAULT 'COLLECTION'::character varying NOT NULL,
    CONSTRAINT chk_receipt_counters_type CHECK (((receipt_type)::text = ANY ((ARRAY['COLLECTION'::character varying, 'REVERSAL'::character varying])::text[]))),
    CONSTRAINT receipt_counters_last_sequence_check CHECK ((last_sequence >= 0))
);


--
-- Name: reconciliation_queue; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reconciliation_queue (
    match_id character varying(100) NOT NULL,
    transaction_id character varying(100) NOT NULL,
    txn_date date NOT NULL,
    amount numeric(15,2) NOT NULL,
    currency character varying(10) DEFAULT 'TRY'::character varying NOT NULL,
    description text NOT NULL,
    sender_name character varying(150),
    sender_iban character varying(34),
    reference_no character varying(100),
    matched_unit_id bigint,
    matched_block character varying(50),
    matched_unit_number integer,
    matched_resident_name character varying(150),
    confidence_score integer DEFAULT 0 NOT NULL,
    matched_due_id bigint,
    outstanding_balance numeric(15,2),
    amount_matches_balance boolean DEFAULT false NOT NULL,
    status character varying(50) NOT NULL,
    notes text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    site_id bigint NOT NULL,
    site_bank_account_id bigint,
    CONSTRAINT chk_reconciliation_status CHECK (((status)::text = ANY ((ARRAY['PENDING_APPROVAL'::character varying, 'APPROVED'::character varying, 'UNMATCHED'::character varying, 'REJECTED'::character varying, 'ALREADY_PROCESSED'::character varying])::text[])))
);


--
-- Name: COLUMN reconciliation_queue.matched_block; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.reconciliation_queue.matched_block IS 'Snapshot at match time; the fact is matched_unit_id';


--
-- Name: COLUMN reconciliation_queue.matched_unit_number; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.reconciliation_queue.matched_unit_number IS 'Snapshot at match time; the fact is matched_unit_id';


--
-- Name: COLUMN reconciliation_queue.matched_resident_name; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.reconciliation_queue.matched_resident_name IS 'Snapshot at match time; the fact is matched_unit_id';


--
-- Name: revaluation_rates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.revaluation_rates (
    year integer NOT NULL,
    rate numeric(7,4) NOT NULL,
    source text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT revaluation_rates_rate_check CHECK ((rate >= (0)::numeric))
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version integer NOT NULL,
    name text NOT NULL,
    checksum text NOT NULL,
    applied_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: site_bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.site_bank_accounts (
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    bank_code character varying(50) NOT NULL,
    bank_name character varying(120) NOT NULL,
    iban character varying(34) NOT NULL,
    account_holder character varying(120) NOT NULL,
    statement_format character varying(30) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    configured_by bigint,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    account_type character varying(30) DEFAULT 'OPERATIONAL'::character varying NOT NULL,
    CONSTRAINT chk_bank_account_type CHECK (((account_type)::text = ANY ((ARRAY['OPERATIONAL'::character varying, 'CAPITAL_RESERVE'::character varying])::text[]))),
    CONSTRAINT chk_bank_iban_format CHECK (((iban)::text ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'::text)),
    CONSTRAINT chk_bank_statement_format CHECK (((statement_format)::text = ANY ((ARRAY['EXCEL'::character varying, 'CSV'::character varying, 'MT940'::character varying])::text[])))
);


--
-- Name: site_bank_accounts_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.site_bank_accounts ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.site_bank_accounts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sites; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sites (
    id bigint NOT NULL,
    name character varying(150) NOT NULL,
    address text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    slug character varying(180),
    status character varying(30) DEFAULT 'ACTIVE'::character varying NOT NULL,
    plan_type character varying(50) DEFAULT 'STANDARD'::character varying NOT NULL,
    license_end_date date,
    timezone character varying(50) DEFAULT 'Europe/Istanbul'::character varying NOT NULL,
    deleted_at timestamp with time zone,
    tax_id character varying(11),
    tax_office character varying(100),
    require_operating_budget boolean DEFAULT false NOT NULL,
    CONSTRAINT chk_sites_plan_type CHECK (((plan_type)::text = ANY ((ARRAY['STANDARD'::character varying, 'PREMIUM'::character varying, 'ENTERPRISE'::character varying])::text[]))),
    CONSTRAINT chk_sites_status CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'SUSPENDED'::character varying, 'TRIAL'::character varying, 'DELETED'::character varying])::text[]))),
    CONSTRAINT chk_sites_tax_id_format CHECK (((tax_id IS NULL) OR ((tax_id)::text ~ '^[0-9]{10,11}$'::text)))
);


--
-- Name: sites_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sites ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sites_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: system_configurations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_configurations (
    config_key character varying(80) NOT NULL,
    config_value character varying(255) NOT NULL,
    description text,
    updated_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: system_supported_banks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.system_supported_banks (
    bank_code character varying(50) NOT NULL,
    bank_name character varying(120) NOT NULL,
    default_statement_format character varying(30) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: unit_occupancies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unit_occupancies (
    id bigint NOT NULL,
    unit_id bigint NOT NULL,
    person_id bigint NOT NULL,
    occupancy_type character varying(20) NOT NULL,
    start_date date DEFAULT CURRENT_DATE NOT NULL,
    end_date date,
    is_active boolean DEFAULT true NOT NULL,
    exit_balance numeric(15,2) DEFAULT 0.00,
    notes text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_occupancy_active_open CHECK (((NOT is_active) OR (end_date IS NULL))),
    CONSTRAINT chk_occupancy_dates CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT chk_occupancy_type CHECK (((occupancy_type)::text = ANY ((ARRAY['OWNER'::character varying, 'TENANT'::character varying])::text[])))
);


--
-- Name: unit_occupancies_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.unit_occupancies ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.unit_occupancies_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: unit_ownerships; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unit_ownerships (
    id bigint NOT NULL,
    unit_id bigint NOT NULL,
    person_id bigint NOT NULL,
    share_percentage numeric(5,2) DEFAULT 100.00 NOT NULL,
    start_date date DEFAULT CURRENT_DATE NOT NULL,
    end_date date,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_ownership_dates CHECK (((end_date IS NULL) OR (end_date >= start_date))),
    CONSTRAINT unit_ownerships_share_percentage_check CHECK (((share_percentage > (0)::numeric) AND (share_percentage <= 100.00)))
);


--
-- Name: unit_ownerships_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.unit_ownerships ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.unit_ownerships_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: unit_payer_names; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unit_payer_names (
    id bigint NOT NULL,
    unit_id bigint NOT NULL,
    payer_name character varying(120) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: unit_payer_names_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.unit_payer_names ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.unit_payer_names_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: unit_sender_ibans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unit_sender_ibans (
    sender_iban character varying(34) NOT NULL,
    unit_id bigint NOT NULL,
    label character varying(100),
    bank_name character varying(100),
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    id bigint NOT NULL,
    site_id bigint NOT NULL,
    CONSTRAINT chk_sender_iban_format CHECK (((sender_iban)::text ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'::text))
);


--
-- Name: unit_sender_ibans_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.unit_sender_ibans ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.unit_sender_ibans_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.units (
    id bigint NOT NULL,
    block_id bigint NOT NULL,
    unit_number integer NOT NULL,
    floor integer NOT NULL,
    land_share integer DEFAULT 1 NOT NULL,
    owner_person_id bigint,
    tenant_person_id bigint,
    site_id bigint NOT NULL,
    virtual_iban character varying(34),
    occupancy_status character varying(20) DEFAULT 'OWNER_OCCUPIED'::character varying NOT NULL,
    house_type character varying(50),
    version integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    house_type_id bigint,
    deleted_at timestamp with time zone,
    CONSTRAINT chk_units_floor CHECK (((floor >= '-5'::integer) AND (floor <= 150))),
    CONSTRAINT chk_units_land_share CHECK ((land_share > 0)),
    CONSTRAINT chk_units_occupancy_status CHECK (((occupancy_status)::text = ANY ((ARRAY['OWNER_OCCUPIED'::character varying, 'TENANT_OCCUPIED'::character varying, 'VACANT'::character varying])::text[])))
);


--
-- Name: units_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.units ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.units_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_site_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_site_roles (
    id bigint NOT NULL,
    user_id bigint NOT NULL,
    site_id bigint NOT NULL,
    role character varying(30) NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT chk_user_site_roles_role CHECK (((role)::text = ANY ((ARRAY['SAAS_ADMIN'::character varying, 'SITE_MANAGER'::character varying, 'HOME_OWNER'::character varying, 'HOME_RESIDENT'::character varying])::text[])))
);


--
-- Name: user_site_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.user_site_roles ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.user_site_roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    id bigint NOT NULL,
    site_id bigint,
    email character varying(120) NOT NULL,
    password_hash character varying(255),
    role character varying(30) NOT NULL,
    must_change_password boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    auth_provider character varying(30) DEFAULT 'LOCAL'::character varying NOT NULL,
    google_sub character varying(100),
    avatar_url character varying(500),
    person_id bigint,
    CONSTRAINT chk_users_auth_provider CHECK (((auth_provider)::text = ANY ((ARRAY['LOCAL'::character varying, 'GOOGLE'::character varying, 'HYBRID'::character varying])::text[]))),
    CONSTRAINT chk_users_role CHECK (((role)::text = ANY ((ARRAY['SAAS_ADMIN'::character varying, 'SITE_MANAGER'::character varying, 'HOME_OWNER'::character varying, 'HOME_RESIDENT'::character varying])::text[])))
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.users ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: v_dues_effective_status; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_dues_effective_status AS
 SELECT id,
    unit_id,
    period,
    status AS stored_status,
        CASE
            WHEN ((status)::text = 'CANCELLED'::text) THEN 'CANCELLED'::text
            WHEN ((paid_principal >= principal_amount) AND (paid_penalty >= delay_penalty)) THEN 'PAID'::text
            WHEN (due_date < CURRENT_DATE) THEN 'OVERDUE'::text
            WHEN (paid_amount > (0)::numeric) THEN 'PARTIALLY_PAID'::text
            ELSE 'PENDING'::text
        END AS effective_status,
    (principal_amount - paid_principal) AS outstanding_principal,
    (delay_penalty - paid_penalty) AS outstanding_penalty
   FROM public.dues_liabilities d;


--
-- Name: v_duplicated_fact_drift; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_duplicated_fact_drift AS
SELECT
    NULL::text AS fact,
    NULL::text AS subject,
    NULL::text AS legacy_value,
    NULL::text AS source_value;


--
-- Name: v_integrity_violations; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_integrity_violations AS
SELECT
    NULL::text AS check_name,
    NULL::text AS subject,
    NULL::numeric AS difference;


--
-- Name: budget_objections id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_objections ALTER COLUMN id SET DEFAULT nextval('public.budget_objections_id_seq'::regclass);


--
-- Name: budget_service_records id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_service_records ALTER COLUMN id SET DEFAULT nextval('public.budget_service_records_id_seq'::regclass);


--
-- Name: operating_budget_lines id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budget_lines ALTER COLUMN id SET DEFAULT nextval('public.operating_budget_lines_id_seq'::regclass);


--
-- Name: operating_budgets id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budgets ALTER COLUMN id SET DEFAULT nextval('public.operating_budgets_id_seq'::regclass);


--
-- Name: payment_intents id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_intents ALTER COLUMN id SET DEFAULT nextval('public.payment_intents_id_seq'::regclass);


--
-- Name: advance_balances advance_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advance_balances
    ADD CONSTRAINT advance_balances_pkey PRIMARY KEY (unit_id, debtor_type);


--
-- Name: advance_ledger_entries advance_ledger_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advance_ledger_entries
    ADD CONSTRAINT advance_ledger_entries_pkey PRIMARY KEY (id);


--
-- Name: blocks blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT blocks_pkey PRIMARY KEY (id);


--
-- Name: budget_objections budget_objections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_objections
    ADD CONSTRAINT budget_objections_pkey PRIMARY KEY (id);


--
-- Name: budget_service_records budget_service_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_service_records
    ADD CONSTRAINT budget_service_records_pkey PRIMARY KEY (id);


--
-- Name: capital_contractor_disbursements capital_contractor_disbursements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_contractor_disbursements
    ADD CONSTRAINT capital_contractor_disbursements_pkey PRIMARY KEY (id);


--
-- Name: capital_project_installments capital_project_installments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_project_installments
    ADD CONSTRAINT capital_project_installments_pkey PRIMARY KEY (id);


--
-- Name: capital_projects capital_projects_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_projects
    ADD CONSTRAINT capital_projects_pkey PRIMARY KEY (id);


--
-- Name: debt_aging_snapshots debt_aging_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.debt_aging_snapshots
    ADD CONSTRAINT debt_aging_snapshots_pkey PRIMARY KEY (id);


--
-- Name: dues_liabilities dues_liabilities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT dues_liabilities_pkey PRIMARY KEY (id);


--
-- Name: dues_periods dues_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_periods
    ADD CONSTRAINT dues_periods_pkey PRIMARY KEY (id);


--
-- Name: house_types house_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.house_types
    ADD CONSTRAINT house_types_pkey PRIMARY KEY (id);


--
-- Name: invitation_tokens invitation_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation_tokens
    ADD CONSTRAINT invitation_tokens_pkey PRIMARY KEY (token);


--
-- Name: occupancy_members occupancy_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.occupancy_members
    ADD CONSTRAINT occupancy_members_pkey PRIMARY KEY (id);


--
-- Name: operating_budget_lines operating_budget_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budget_lines
    ADD CONSTRAINT operating_budget_lines_pkey PRIMARY KEY (id);


--
-- Name: operating_budget_unit_shares operating_budget_unit_shares_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budget_unit_shares
    ADD CONSTRAINT operating_budget_unit_shares_pkey PRIMARY KEY (budget_id, unit_id);


--
-- Name: operating_budgets operating_budgets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budgets
    ADD CONSTRAINT operating_budgets_pkey PRIMARY KEY (id);


--
-- Name: payment_allocations payment_allocations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_allocations
    ADD CONSTRAINT payment_allocations_pkey PRIMARY KEY (id);


--
-- Name: payment_entries payment_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT payment_entries_pkey PRIMARY KEY (id);


--
-- Name: payment_idempotency_keys payment_idempotency_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_idempotency_keys
    ADD CONSTRAINT payment_idempotency_keys_pkey PRIMARY KEY (site_id, idempotency_key);


--
-- Name: payment_intents payment_intents_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_intents
    ADD CONSTRAINT payment_intents_pkey PRIMARY KEY (id);


--
-- Name: payment_receipts payment_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT payment_receipts_pkey PRIMARY KEY (id);


--
-- Name: pending_registrations pending_registrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_registrations
    ADD CONSTRAINT pending_registrations_pkey PRIMARY KEY (request_id);


--
-- Name: persons persons_national_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.persons
    ADD CONSTRAINT persons_national_id_key UNIQUE (national_id);


--
-- Name: persons persons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.persons
    ADD CONSTRAINT persons_pkey PRIMARY KEY (id);


--
-- Name: pii_settings pii_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pii_settings
    ADD CONSTRAINT pii_settings_pkey PRIMARY KEY (id);


--
-- Name: processed_bank_webhooks processed_bank_webhooks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_bank_webhooks
    ADD CONSTRAINT processed_bank_webhooks_pkey PRIMARY KEY (id);


--
-- Name: receipt_counters receipt_counters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_counters
    ADD CONSTRAINT receipt_counters_pkey PRIMARY KEY (site_id, receipt_type);


--
-- Name: reconciliation_queue reconciliation_queue_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_queue
    ADD CONSTRAINT reconciliation_queue_pkey PRIMARY KEY (match_id);


--
-- Name: revaluation_rates revaluation_rates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.revaluation_rates
    ADD CONSTRAINT revaluation_rates_pkey PRIMARY KEY (year);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: site_bank_accounts site_bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_bank_accounts
    ADD CONSTRAINT site_bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: sites sites_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_pkey PRIMARY KEY (id);


--
-- Name: sites sites_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sites
    ADD CONSTRAINT sites_slug_key UNIQUE (slug);


--
-- Name: system_configurations system_configurations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_configurations
    ADD CONSTRAINT system_configurations_pkey PRIMARY KEY (config_key);


--
-- Name: system_supported_banks system_supported_banks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.system_supported_banks
    ADD CONSTRAINT system_supported_banks_pkey PRIMARY KEY (bank_code);


--
-- Name: unit_occupancies unit_occupancies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_occupancies
    ADD CONSTRAINT unit_occupancies_pkey PRIMARY KEY (id);


--
-- Name: unit_ownerships unit_ownerships_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_ownerships
    ADD CONSTRAINT unit_ownerships_pkey PRIMARY KEY (id);


--
-- Name: unit_payer_names unit_payer_names_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_payer_names
    ADD CONSTRAINT unit_payer_names_pkey PRIMARY KEY (id);


--
-- Name: unit_sender_ibans unit_sender_ibans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_sender_ibans
    ADD CONSTRAINT unit_sender_ibans_pkey PRIMARY KEY (id);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: units uq_block_unit; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT uq_block_unit UNIQUE (block_id, unit_number);


--
-- Name: budget_service_records uq_budget_service_unit; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_service_records
    ADD CONSTRAINT uq_budget_service_unit UNIQUE (budget_id, unit_id);


--
-- Name: payment_intents uq_payment_intents_provider_ref; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_intents
    ADD CONSTRAINT uq_payment_intents_provider_ref UNIQUE (provider, provider_ref);


--
-- Name: persons uq_persons_email; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.persons
    ADD CONSTRAINT uq_persons_email UNIQUE (email);


--
-- Name: capital_project_installments uq_project_installment; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_project_installments
    ADD CONSTRAINT uq_project_installment UNIQUE (project_id, installment_number);


--
-- Name: house_types uq_site_house_type; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.house_types
    ADD CONSTRAINT uq_site_house_type UNIQUE (site_id, type_name);


--
-- Name: dues_periods uq_site_period_name; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_periods
    ADD CONSTRAINT uq_site_period_name UNIQUE (site_id, period_name);


--
-- Name: payment_receipts uq_site_receipt_number; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT uq_site_receipt_number UNIQUE (site_id, receipt_number);


--
-- Name: debt_aging_snapshots uq_unit_debtor_aging; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.debt_aging_snapshots
    ADD CONSTRAINT uq_unit_debtor_aging UNIQUE (site_id, unit_id, debtor_type, as_of_date);


--
-- Name: unit_payer_names uq_unit_payer; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_payer_names
    ADD CONSTRAINT uq_unit_payer UNIQUE (unit_id, payer_name);


--
-- Name: unit_sender_ibans uq_unit_sender_iban; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_sender_ibans
    ADD CONSTRAINT uq_unit_sender_iban UNIQUE (unit_id, sender_iban);


--
-- Name: user_site_roles uq_user_site_role; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_site_roles
    ADD CONSTRAINT uq_user_site_role UNIQUE (user_id, site_id, role);


--
-- Name: user_site_roles user_site_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_site_roles
    ADD CONSTRAINT user_site_roles_pkey PRIMARY KEY (id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: idx_advance_ledger_reference; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_advance_ledger_reference ON public.advance_ledger_entries USING btree (reference_id) WHERE (reference_id IS NOT NULL);


--
-- Name: idx_advance_ledger_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_advance_ledger_unit ON public.advance_ledger_entries USING btree (unit_id, debtor_type);


--
-- Name: idx_allocations_liability; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_allocations_liability ON public.payment_allocations USING btree (dues_liability_id);


--
-- Name: idx_allocations_payment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_allocations_payment ON public.payment_allocations USING btree (payment_entry_id);


--
-- Name: idx_blocks_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_blocks_site_id ON public.blocks USING btree (site_id);


--
-- Name: idx_capital_projects_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_capital_projects_site ON public.capital_projects USING btree (site_id);


--
-- Name: idx_contractor_disbursements_proj; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_contractor_disbursements_proj ON public.capital_contractor_disbursements USING btree (project_id);


--
-- Name: idx_debt_aging_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_debt_aging_unit ON public.debt_aging_snapshots USING btree (unit_id);


--
-- Name: idx_dues_liabilities_capital_proj; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_capital_proj ON public.dues_liabilities USING btree (capital_project_id);


--
-- Name: idx_dues_liabilities_installment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_installment ON public.dues_liabilities USING btree (capital_project_installment_id);


--
-- Name: idx_dues_liabilities_occupancy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_occupancy ON public.dues_liabilities USING btree (occupancy_id);


--
-- Name: idx_dues_liabilities_operating_budget; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_operating_budget ON public.dues_liabilities USING btree (operating_budget_id) WHERE (operating_budget_id IS NOT NULL);


--
-- Name: idx_dues_liabilities_period; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_period ON public.dues_liabilities USING btree (dues_period_id);


--
-- Name: idx_dues_liabilities_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_person ON public.dues_liabilities USING btree (liable_person_id);


--
-- Name: idx_dues_liabilities_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_liabilities_unit ON public.dues_liabilities USING btree (unit_id);


--
-- Name: idx_dues_periods_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_periods_site ON public.dues_periods USING btree (site_id);


--
-- Name: idx_dues_unit_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_dues_unit_status ON public.dues_liabilities USING btree (unit_id, status);


--
-- Name: idx_invitation_tokens_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_tokens_expires ON public.invitation_tokens USING btree (expires_at);


--
-- Name: idx_invitation_tokens_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_tokens_site ON public.invitation_tokens USING btree (site_id);


--
-- Name: idx_invitation_tokens_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invitation_tokens_unit ON public.invitation_tokens USING btree (unit_id);


--
-- Name: idx_occupancies_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_occupancies_person ON public.unit_occupancies USING btree (person_id);


--
-- Name: idx_occupancies_unit_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_occupancies_unit_id ON public.unit_occupancies USING btree (unit_id);


--
-- Name: idx_occupancy_members_full_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_occupancy_members_full_name ON public.occupancy_members USING btree (occupancy_id, full_name);


--
-- Name: idx_occupancy_members_occ; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_occupancy_members_occ ON public.occupancy_members USING btree (occupancy_id);


--
-- Name: idx_occupancy_members_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_occupancy_members_person ON public.occupancy_members USING btree (person_id);


--
-- Name: idx_occupancy_members_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_occupancy_members_user ON public.occupancy_members USING btree (resident_user_id);


--
-- Name: idx_operating_budget_lines_budget; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_operating_budget_lines_budget ON public.operating_budget_lines USING btree (budget_id);


--
-- Name: idx_operating_budgets_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_operating_budgets_site ON public.operating_budgets USING btree (site_id, fiscal_year);


--
-- Name: idx_payment_entries_external_ref; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_external_ref ON public.payment_entries USING btree (site_id, external_reference) WHERE (external_reference IS NOT NULL);


--
-- Name: idx_payment_entries_occupancy; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_occupancy ON public.payment_entries USING btree (occupancy_id);


--
-- Name: idx_payment_entries_payer_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_payer_person ON public.payment_entries USING btree (payer_person_id);


--
-- Name: idx_payment_entries_receipt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_receipt ON public.payment_entries USING btree (receipt_id);


--
-- Name: idx_payment_entries_site_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_site_date ON public.payment_entries USING btree (site_id, payment_date DESC);


--
-- Name: idx_payment_entries_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_unit ON public.payment_entries USING btree (unit_id, payment_date DESC);


--
-- Name: idx_payment_entries_unmatched; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_entries_unmatched ON public.payment_entries USING btree (site_id, payment_date) WHERE ((settlement_status)::text = 'UNMATCHED'::text);


--
-- Name: idx_payment_intents_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_intents_unit ON public.payment_intents USING btree (unit_id, created_at DESC);


--
-- Name: idx_payment_receipts_on_behalf_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_receipts_on_behalf_person ON public.payment_receipts USING btree (on_behalf_of_person_id);


--
-- Name: idx_payment_receipts_payer_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_payment_receipts_payer_person ON public.payment_receipts USING btree (payer_person_id);


--
-- Name: idx_pending_reg_site_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_reg_site_status ON public.pending_registrations USING btree (site_id, status);


--
-- Name: idx_processed_webhooks_bank_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_webhooks_bank_account ON public.processed_bank_webhooks USING btree (site_bank_account_id);


--
-- Name: idx_processed_webhooks_receipt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_webhooks_receipt ON public.processed_bank_webhooks USING btree (receipt_id);


--
-- Name: idx_processed_webhooks_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_processed_webhooks_site ON public.processed_bank_webhooks USING btree (site_id);


--
-- Name: idx_project_installments_proj; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_project_installments_proj ON public.capital_project_installments USING btree (project_id);


--
-- Name: idx_receipts_site_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_receipts_site_date ON public.payment_receipts USING btree (site_id, issued_at DESC);


--
-- Name: idx_receipts_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_receipts_unit ON public.payment_receipts USING btree (unit_id);


--
-- Name: idx_reconciliation_bank_account; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconciliation_bank_account ON public.reconciliation_queue USING btree (site_bank_account_id);


--
-- Name: idx_reconciliation_queue_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconciliation_queue_due ON public.reconciliation_queue USING btree (matched_due_id);


--
-- Name: idx_reconciliation_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconciliation_site ON public.reconciliation_queue USING btree (site_id);


--
-- Name: idx_reconciliation_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reconciliation_unit ON public.reconciliation_queue USING btree (matched_unit_id);


--
-- Name: idx_site_bank_account_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_bank_account_site ON public.site_bank_accounts USING btree (site_id);


--
-- Name: idx_site_bank_accounts_config_by; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_site_bank_accounts_config_by ON public.site_bank_accounts USING btree (configured_by);


--
-- Name: idx_unit_ownerships_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_unit_ownerships_active ON public.unit_ownerships USING btree (unit_id) WHERE (is_active = true);


--
-- Name: idx_unit_ownerships_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_unit_ownerships_person ON public.unit_ownerships USING btree (person_id);


--
-- Name: idx_unit_payer_names_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_unit_payer_names_unit ON public.unit_payer_names USING btree (unit_id);


--
-- Name: idx_unit_sender_ibans_unit; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_unit_sender_ibans_unit ON public.unit_sender_ibans USING btree (unit_id);


--
-- Name: idx_units_house_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_units_house_type ON public.units USING btree (house_type_id);


--
-- Name: idx_units_owner_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_units_owner_person ON public.units USING btree (owner_person_id);


--
-- Name: idx_units_site_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_units_site_id ON public.units USING btree (site_id);


--
-- Name: idx_units_tenant_person; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_units_tenant_person ON public.units USING btree (tenant_person_id);


--
-- Name: idx_user_auth_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_auth_provider ON public.users USING btree (auth_provider);


--
-- Name: idx_user_site; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_site ON public.users USING btree (site_id);


--
-- Name: idx_user_site_roles_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_site_roles_lookup ON public.user_site_roles USING btree (site_id, role);


--
-- Name: idx_users_person_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_person_id ON public.users USING btree (person_id);


--
-- Name: uq_blocks_id_site; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_blocks_id_site ON public.blocks USING btree (id, site_id);


--
-- Name: uq_occupancy_member_person; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_occupancy_member_person ON public.occupancy_members USING btree (occupancy_id, person_id) WHERE (person_id IS NOT NULL);


--
-- Name: uq_operating_budgets_in_force; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_operating_budgets_in_force ON public.operating_budgets USING btree (site_id, fiscal_year) WHERE ((status)::text = ANY ((ARRAY['INTERIM'::character varying, 'APPROVED'::character varying, 'FINAL'::character varying])::text[]));


--
-- Name: uq_payment_allocation_line; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_payment_allocation_line ON public.payment_allocations USING btree (payment_entry_id, dues_liability_id);


--
-- Name: uq_payment_entries_receipt; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_payment_entries_receipt ON public.payment_entries USING btree (receipt_id) WHERE (receipt_id IS NOT NULL);


--
-- Name: uq_payment_entries_reverses; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_payment_entries_reverses ON public.payment_entries USING btree (reverses_entry_id) WHERE (reverses_entry_id IS NOT NULL);


--
-- Name: uq_payment_receipts_reverses; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_payment_receipts_reverses ON public.payment_receipts USING btree (reverses_receipt_id) WHERE (reverses_receipt_id IS NOT NULL);


--
-- Name: uq_persons_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_persons_email_lower ON public.persons USING btree (lower((email)::text)) WHERE ((email IS NOT NULL) AND ((email)::text <> ''::text));


--
-- Name: uq_persons_national_id_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_persons_national_id_hash ON public.persons USING btree (national_id_hash) WHERE (national_id_hash IS NOT NULL);


--
-- Name: uq_processed_webhooks_scope_txn; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_processed_webhooks_scope_txn ON public.processed_bank_webhooks USING btree (scope_key, transaction_id);


--
-- Name: uq_site_active_bank_type; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_site_active_bank_type ON public.site_bank_accounts USING btree (site_id, account_type) WHERE (is_active = true);


--
-- Name: uq_site_block_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_site_block_name ON public.blocks USING btree (site_id, block_name);


--
-- Name: uq_site_receipt_series_sequence; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_site_receipt_series_sequence ON public.payment_receipts USING btree (site_id, receipt_type, sequence_number);


--
-- Name: uq_site_sender_iban; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_site_sender_iban ON public.unit_sender_ibans USING btree (site_id, sender_iban);


--
-- Name: uq_unit_active_occupancy; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_unit_active_occupancy ON public.unit_occupancies USING btree (unit_id) WHERE (is_active = true);


--
-- Name: uq_unit_active_owner; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_unit_active_owner ON public.unit_ownerships USING btree (unit_id, person_id) WHERE (is_active = true);


--
-- Name: uq_unit_capital_installment; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_unit_capital_installment ON public.dues_liabilities USING btree (unit_id, capital_project_id, installment_number) WHERE (capital_project_id IS NOT NULL);


--
-- Name: uq_unit_period_expense; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_unit_period_expense ON public.dues_liabilities USING btree (unit_id, period, expense_type) WHERE (capital_project_id IS NULL);


--
-- Name: uq_units_virtual_iban; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_units_virtual_iban ON public.units USING btree (virtual_iban) WHERE (virtual_iban IS NOT NULL);


--
-- Name: uq_user_google_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_user_google_sub ON public.users USING btree (google_sub) WHERE (google_sub IS NOT NULL);


--
-- Name: uq_users_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uq_users_email_lower ON public.users USING btree (lower((email)::text));


--
-- Name: v_duplicated_fact_drift _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.v_duplicated_fact_drift AS
 SELECT 'units.owner_person_id'::text AS fact,
    (u.id)::text AS subject,
    (u.owner_person_id)::text AS legacy_value,
    (o.person_id)::text AS source_value
   FROM (public.units u
     JOIN LATERAL ( SELECT x.person_id
           FROM public.unit_ownerships x
          WHERE ((x.unit_id = u.id) AND x.is_active)
          ORDER BY x.share_percentage DESC, x.start_date DESC, x.id DESC
         LIMIT 1) o ON (true))
  WHERE (u.owner_person_id IS DISTINCT FROM o.person_id)
UNION ALL
 SELECT 'users.site_id/role'::text AS fact,
    (us.id)::text AS subject,
    (((us.site_id)::text || '/'::text) || (us.role)::text) AS legacy_value,
    (((r.site_id)::text || '/'::text) || (r.role)::text) AS source_value
   FROM (public.users us
     JOIN public.user_site_roles r ON ((r.user_id = us.id)))
  WHERE ((us.site_id IS NOT NULL) AND (NOT (EXISTS ( SELECT 1
           FROM public.user_site_roles r2
          WHERE ((r2.user_id = us.id) AND (r2.site_id = us.site_id) AND ((r2.role)::text = (us.role)::text))))))
UNION ALL
 SELECT 'dues_liabilities.period/dues_period_id'::text AS fact,
    (d.id)::text AS subject,
    d.period AS legacy_value,
    p.period_name AS source_value
   FROM (public.dues_liabilities d
     JOIN public.dues_periods p ON ((p.id = d.dues_period_id)))
  WHERE ((d.period)::text <> (p.period_name)::text)
UNION ALL
 SELECT 'payment_receipts.allocated_*/payment_allocations'::text AS fact,
    (r.id)::text AS subject,
    ((r.allocated_principal + r.allocated_penalty))::text AS legacy_value,
    (COALESCE(sum((pa.principal_amount + pa.penalty_amount)), (0)::numeric))::text AS source_value
   FROM ((public.payment_receipts r
     JOIN public.payment_entries e ON ((e.receipt_id = r.id)))
     LEFT JOIN public.payment_allocations pa ON ((pa.payment_entry_id = e.id)))
  WHERE ((r.receipt_type)::text = 'COLLECTION'::text)
  GROUP BY r.id
 HAVING ((r.allocated_principal + r.allocated_penalty) <> COALESCE(sum((pa.principal_amount + pa.penalty_amount)), (0)::numeric));


--
-- Name: v_integrity_violations _RETURN; Type: RULE; Schema: public; Owner: -
--

CREATE OR REPLACE VIEW public.v_integrity_violations AS
 SELECT 'advance_balance_vs_ledger'::text AS check_name,
    (((ab.unit_id)::text || '/'::text) || (ab.debtor_type)::text) AS subject,
    (ab.balance - COALESCE(l.net, (0)::numeric)) AS difference
   FROM (public.advance_balances ab
     LEFT JOIN ( SELECT advance_ledger_entries.unit_id,
            advance_ledger_entries.debtor_type,
            sum(
                CASE
                    WHEN ((advance_ledger_entries.entry_type)::text = ANY ((ARRAY['PAYMENT_SURPLUS'::character varying, 'ADJUSTMENT_CREDIT'::character varying, 'VIRMAN_REVERSAL'::character varying])::text[])) THEN advance_ledger_entries.amount
                    WHEN ((advance_ledger_entries.entry_type)::text = 'ADJUSTMENT'::text) THEN (0)::numeric
                    ELSE (- advance_ledger_entries.amount)
                END) AS net
           FROM public.advance_ledger_entries
          GROUP BY advance_ledger_entries.unit_id, advance_ledger_entries.debtor_type) l ON (((l.unit_id = ab.unit_id) AND ((l.debtor_type)::text = (ab.debtor_type)::text))))
  WHERE (ab.balance <> COALESCE(l.net, (0)::numeric))
UNION ALL
 SELECT 'installment_percentages'::text AS check_name,
    (capital_project_installments.project_id)::text AS subject,
    (sum(capital_project_installments.percentage) - (100)::numeric) AS difference
   FROM public.capital_project_installments
  GROUP BY capital_project_installments.project_id
 HAVING (sum(capital_project_installments.percentage) <> (100)::numeric)
UNION ALL
 SELECT 'allocations_vs_dues_paid'::text AS check_name,
    (d.id)::text AS subject,
    ((d.paid_principal + d.paid_penalty) - COALESCE(sum((pa.principal_amount + pa.penalty_amount)), (0)::numeric)) AS difference
   FROM (public.dues_liabilities d
     LEFT JOIN public.payment_allocations pa ON (((pa.dues_liability_id = d.id) AND (NOT (EXISTS ( SELECT 1
           FROM public.payment_entries re
          WHERE ((re.id = pa.payment_entry_id) AND ((re.settlement_status)::text = 'REVERSED'::text))))))))
  GROUP BY d.id
 HAVING ((EXISTS ( SELECT 1
           FROM public.payment_allocations x
          WHERE (x.dues_liability_id = d.id))) AND ((d.paid_principal + d.paid_penalty) <> COALESCE(sum((pa.principal_amount + pa.penalty_amount)), (0)::numeric)))
UNION ALL
 SELECT 'allocations_exceed_entry_amount'::text AS check_name,
    (e.id)::text AS subject,
    (COALESCE(sum((pa.principal_amount + pa.penalty_amount)), (0)::numeric) - e.amount) AS difference
   FROM (public.payment_entries e
     JOIN public.payment_allocations pa ON ((pa.payment_entry_id = e.id)))
  GROUP BY e.id, e.amount
 HAVING (COALESCE(sum((pa.principal_amount + pa.penalty_amount)), (0)::numeric) > e.amount)
UNION ALL
 SELECT 'entry_vs_receipt_amount'::text AS check_name,
    (e.id)::text AS subject,
    (e.amount - r.total_amount) AS difference
   FROM (public.payment_entries e
     JOIN public.payment_receipts r ON ((r.id = e.receipt_id)))
  WHERE ((e.amount <> r.total_amount) AND ((e.payment_channel)::text <> 'INTER_LEDGER'::text))
UNION ALL
 SELECT 'reversal_vs_original'::text AS check_name,
    (re.id)::text AS subject,
    (re.amount - o.amount) AS difference
   FROM (public.payment_entries re
     JOIN public.payment_entries o ON ((o.id = re.reverses_entry_id)))
  WHERE ((re.amount <> o.amount) OR ((o.settlement_status)::text <> 'REVERSED'::text) OR (re.unit_id <> o.unit_id))
UNION ALL
 SELECT 'reversal_receipt_vs_original'::text AS check_name,
    (rr.id)::text AS subject,
    (rr.total_amount - orr.total_amount) AS difference
   FROM (public.payment_receipts rr
     JOIN public.payment_receipts orr ON ((orr.id = rr.reverses_receipt_id)))
  WHERE ((rr.total_amount <> orr.total_amount) OR (rr.allocated_principal <> orr.allocated_principal) OR (rr.allocated_penalty <> orr.allocated_penalty) OR (rr.allocated_advance <> orr.allocated_advance))
UNION ALL
 SELECT 'budget_shares_vs_lines'::text AS check_name,
    (b.id)::text AS subject,
    (COALESCE(( SELECT sum(s.annual_amount) AS sum
           FROM public.operating_budget_unit_shares s
          WHERE (s.budget_id = b.id)), (0)::numeric) - COALESCE(( SELECT sum(l.annual_amount) AS sum
           FROM public.operating_budget_lines l
          WHERE (l.budget_id = b.id)), (0)::numeric)) AS difference
   FROM public.operating_budgets b
  WHERE (((b.status)::text <> 'DRAFT'::text) AND (COALESCE(( SELECT sum(s.annual_amount) AS sum
           FROM public.operating_budget_unit_shares s
          WHERE (s.budget_id = b.id)), (0)::numeric) <> COALESCE(( SELECT sum(l.annual_amount) AS sum
           FROM public.operating_budget_lines l
          WHERE (l.budget_id = b.id)), (0)::numeric)))
UNION ALL
 SELECT 'captured_intent_without_receipt'::text AS check_name,
    (pi.id)::text AS subject,
    pi.amount AS difference
   FROM public.payment_intents pi
  WHERE (((pi.status)::text = ANY ((ARRAY['CAPTURED'::character varying, 'REFUNDED'::character varying])::text[])) AND (NOT (EXISTS ( SELECT 1
           FROM public.payment_receipts r
          WHERE ((r.site_id = pi.site_id) AND ((r.receipt_number)::text = (pi.receipt_number)::text))))));


--
-- Name: advance_ledger_entries trg_advance_ledger_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_advance_ledger_append_only BEFORE DELETE OR UPDATE ON public.advance_ledger_entries FOR EACH ROW EXECUTE FUNCTION public.sp_ledger_append_only();


--
-- Name: payment_idempotency_keys trg_idempotency_keys_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_idempotency_keys_append_only BEFORE DELETE OR UPDATE ON public.payment_idempotency_keys FOR EACH ROW EXECUTE FUNCTION public.sp_ledger_append_only();


--
-- Name: payment_allocations trg_payment_allocations_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payment_allocations_append_only BEFORE DELETE OR UPDATE ON public.payment_allocations FOR EACH ROW EXECUTE FUNCTION public.sp_ledger_append_only();


--
-- Name: payment_entries trg_payment_entries_guard; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payment_entries_guard BEFORE DELETE OR UPDATE ON public.payment_entries FOR EACH ROW EXECUTE FUNCTION public.sp_payment_entry_guard();


--
-- Name: payment_receipts trg_payment_receipts_append_only; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_payment_receipts_append_only BEFORE DELETE OR UPDATE ON public.payment_receipts FOR EACH ROW EXECUTE FUNCTION public.sp_ledger_append_only();


--
-- Name: persons trg_protect_national_id; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_protect_national_id BEFORE INSERT OR UPDATE OF national_id ON public.persons FOR EACH ROW EXECUTE FUNCTION public.sp_protect_national_id();


--
-- Name: unit_ownerships trg_sync_unit_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_unit_owner AFTER INSERT OR DELETE OR UPDATE ON public.unit_ownerships FOR EACH ROW EXECUTE FUNCTION public.sp_sync_unit_owner();


--
-- Name: unit_occupancies trg_sync_unit_tenant; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_sync_unit_tenant AFTER INSERT OR DELETE OR UPDATE ON public.unit_occupancies FOR EACH ROW EXECUTE FUNCTION public.sp_sync_unit_tenant();


--
-- Name: budget_objections budget_objections_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_objections
    ADD CONSTRAINT budget_objections_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.operating_budgets(id) ON DELETE CASCADE;


--
-- Name: budget_objections budget_objections_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_objections
    ADD CONSTRAINT budget_objections_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: budget_service_records budget_service_records_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_service_records
    ADD CONSTRAINT budget_service_records_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.operating_budgets(id) ON DELETE CASCADE;


--
-- Name: budget_service_records budget_service_records_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.budget_service_records
    ADD CONSTRAINT budget_service_records_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: capital_contractor_disbursements capital_contractor_disbursements_project_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_contractor_disbursements
    ADD CONSTRAINT capital_contractor_disbursements_project_id_fkey FOREIGN KEY (project_id) REFERENCES public.capital_projects(id) ON DELETE CASCADE;


--
-- Name: dues_liabilities dues_liabilities_capital_project_installment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT dues_liabilities_capital_project_installment_id_fkey FOREIGN KEY (capital_project_installment_id) REFERENCES public.capital_project_installments(id) ON DELETE RESTRICT;


--
-- Name: dues_liabilities dues_liabilities_dues_period_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT dues_liabilities_dues_period_id_fkey FOREIGN KEY (dues_period_id) REFERENCES public.dues_periods(id) ON DELETE RESTRICT;


--
-- Name: dues_liabilities dues_liabilities_liable_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT dues_liabilities_liable_person_id_fkey FOREIGN KEY (liable_person_id) REFERENCES public.persons(id);


--
-- Name: dues_liabilities dues_liabilities_occupancy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT dues_liabilities_occupancy_id_fkey FOREIGN KEY (occupancy_id) REFERENCES public.unit_occupancies(id);


--
-- Name: advance_balances fk_advance_balances_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advance_balances
    ADD CONSTRAINT fk_advance_balances_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: advance_ledger_entries fk_advance_ledger_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.advance_ledger_entries
    ADD CONSTRAINT fk_advance_ledger_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: blocks fk_blocks_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blocks
    ADD CONSTRAINT fk_blocks_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT NOT VALID;


--
-- Name: capital_project_installments fk_capital_installments_project; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_project_installments
    ADD CONSTRAINT fk_capital_installments_project FOREIGN KEY (project_id) REFERENCES public.capital_projects(id) ON DELETE RESTRICT;


--
-- Name: capital_projects fk_capital_projects_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.capital_projects
    ADD CONSTRAINT fk_capital_projects_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: debt_aging_snapshots fk_debt_aging_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.debt_aging_snapshots
    ADD CONSTRAINT fk_debt_aging_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: debt_aging_snapshots fk_debt_aging_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.debt_aging_snapshots
    ADD CONSTRAINT fk_debt_aging_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: dues_liabilities fk_dues_capital_project; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT fk_dues_capital_project FOREIGN KEY (capital_project_id) REFERENCES public.capital_projects(id) ON DELETE RESTRICT;


--
-- Name: dues_liabilities fk_dues_liabilities_operating_budget; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT fk_dues_liabilities_operating_budget FOREIGN KEY (operating_budget_id) REFERENCES public.operating_budgets(id) ON DELETE RESTRICT;


--
-- Name: dues_liabilities fk_dues_liabilities_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_liabilities
    ADD CONSTRAINT fk_dues_liabilities_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: dues_periods fk_dues_periods_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dues_periods
    ADD CONSTRAINT fk_dues_periods_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: house_types fk_house_types_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.house_types
    ADD CONSTRAINT fk_house_types_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: invitation_tokens fk_invitation_tokens_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation_tokens
    ADD CONSTRAINT fk_invitation_tokens_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: invitation_tokens fk_invitation_tokens_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invitation_tokens
    ADD CONSTRAINT fk_invitation_tokens_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE CASCADE;


--
-- Name: payment_allocations fk_payment_allocations_entry; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_allocations
    ADD CONSTRAINT fk_payment_allocations_entry FOREIGN KEY (payment_entry_id) REFERENCES public.payment_entries(id) ON DELETE RESTRICT;


--
-- Name: payment_entries fk_payment_entries_occupancy; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT fk_payment_entries_occupancy FOREIGN KEY (occupancy_id) REFERENCES public.unit_occupancies(id) ON DELETE RESTRICT;


--
-- Name: payment_entries fk_payment_entries_payer_person; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT fk_payment_entries_payer_person FOREIGN KEY (payer_person_id) REFERENCES public.persons(id) ON DELETE RESTRICT;


--
-- Name: payment_entries fk_payment_entries_receipt; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT fk_payment_entries_receipt FOREIGN KEY (receipt_id) REFERENCES public.payment_receipts(id) ON DELETE RESTRICT;


--
-- Name: payment_entries fk_payment_entries_reverses; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT fk_payment_entries_reverses FOREIGN KEY (reverses_entry_id) REFERENCES public.payment_entries(id) ON DELETE RESTRICT;


--
-- Name: payment_entries fk_payment_entries_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT fk_payment_entries_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: payment_entries fk_payment_entries_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_entries
    ADD CONSTRAINT fk_payment_entries_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: payment_receipts fk_payment_receipts_on_behalf_person; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT fk_payment_receipts_on_behalf_person FOREIGN KEY (on_behalf_of_person_id) REFERENCES public.persons(id) ON DELETE RESTRICT;


--
-- Name: payment_receipts fk_payment_receipts_payer_person; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT fk_payment_receipts_payer_person FOREIGN KEY (payer_person_id) REFERENCES public.persons(id) ON DELETE RESTRICT;


--
-- Name: payment_receipts fk_payment_receipts_reverses; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT fk_payment_receipts_reverses FOREIGN KEY (reverses_receipt_id) REFERENCES public.payment_receipts(id) ON DELETE RESTRICT;


--
-- Name: payment_receipts fk_payment_receipts_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT fk_payment_receipts_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: payment_receipts fk_payment_receipts_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_receipts
    ADD CONSTRAINT fk_payment_receipts_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: pending_registrations fk_pending_registrations_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_registrations
    ADD CONSTRAINT fk_pending_registrations_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: processed_bank_webhooks fk_processed_webhooks_bank_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_bank_webhooks
    ADD CONSTRAINT fk_processed_webhooks_bank_account FOREIGN KEY (site_bank_account_id) REFERENCES public.site_bank_accounts(id) ON DELETE RESTRICT;


--
-- Name: processed_bank_webhooks fk_processed_webhooks_receipt; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_bank_webhooks
    ADD CONSTRAINT fk_processed_webhooks_receipt FOREIGN KEY (receipt_id) REFERENCES public.payment_receipts(id) ON DELETE RESTRICT;


--
-- Name: processed_bank_webhooks fk_processed_webhooks_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.processed_bank_webhooks
    ADD CONSTRAINT fk_processed_webhooks_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: reconciliation_queue fk_reconciliation_bank_account; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_queue
    ADD CONSTRAINT fk_reconciliation_bank_account FOREIGN KEY (site_bank_account_id) REFERENCES public.site_bank_accounts(id) ON DELETE RESTRICT;


--
-- Name: reconciliation_queue fk_reconciliation_due; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_queue
    ADD CONSTRAINT fk_reconciliation_due FOREIGN KEY (matched_due_id) REFERENCES public.dues_liabilities(id) ON DELETE SET NULL;


--
-- Name: reconciliation_queue fk_reconciliation_queue_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_queue
    ADD CONSTRAINT fk_reconciliation_queue_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: reconciliation_queue fk_reconciliation_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reconciliation_queue
    ADD CONSTRAINT fk_reconciliation_unit FOREIGN KEY (matched_unit_id) REFERENCES public.units(id) ON DELETE SET NULL;


--
-- Name: unit_occupancies fk_unit_occupancies_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_occupancies
    ADD CONSTRAINT fk_unit_occupancies_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: unit_ownerships fk_unit_ownerships_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_ownerships
    ADD CONSTRAINT fk_unit_ownerships_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: unit_payer_names fk_unit_payer_names_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_payer_names
    ADD CONSTRAINT fk_unit_payer_names_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE CASCADE;


--
-- Name: unit_sender_ibans fk_unit_sender_ibans_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_sender_ibans
    ADD CONSTRAINT fk_unit_sender_ibans_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: unit_sender_ibans fk_unit_sender_ibans_unit; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_sender_ibans
    ADD CONSTRAINT fk_unit_sender_ibans_unit FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE CASCADE;


--
-- Name: units fk_units_block_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT fk_units_block_site FOREIGN KEY (block_id, site_id) REFERENCES public.blocks(id, site_id) ON DELETE RESTRICT;


--
-- Name: users fk_users_site; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_users_site FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: occupancy_members occupancy_members_occupancy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.occupancy_members
    ADD CONSTRAINT occupancy_members_occupancy_id_fkey FOREIGN KEY (occupancy_id) REFERENCES public.unit_occupancies(id) ON DELETE CASCADE;


--
-- Name: occupancy_members occupancy_members_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.occupancy_members
    ADD CONSTRAINT occupancy_members_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.persons(id) ON DELETE SET NULL;


--
-- Name: occupancy_members occupancy_members_resident_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.occupancy_members
    ADD CONSTRAINT occupancy_members_resident_user_id_fkey FOREIGN KEY (resident_user_id) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: operating_budget_lines operating_budget_lines_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budget_lines
    ADD CONSTRAINT operating_budget_lines_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.operating_budgets(id) ON DELETE CASCADE;


--
-- Name: operating_budget_unit_shares operating_budget_unit_shares_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budget_unit_shares
    ADD CONSTRAINT operating_budget_unit_shares_budget_id_fkey FOREIGN KEY (budget_id) REFERENCES public.operating_budgets(id) ON DELETE CASCADE;


--
-- Name: operating_budget_unit_shares operating_budget_unit_shares_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budget_unit_shares
    ADD CONSTRAINT operating_budget_unit_shares_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: operating_budgets operating_budgets_previous_budget_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budgets
    ADD CONSTRAINT operating_budgets_previous_budget_id_fkey FOREIGN KEY (previous_budget_id) REFERENCES public.operating_budgets(id) ON DELETE SET NULL;


--
-- Name: operating_budgets operating_budgets_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.operating_budgets
    ADD CONSTRAINT operating_budgets_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: payment_allocations payment_allocations_dues_liability_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_allocations
    ADD CONSTRAINT payment_allocations_dues_liability_id_fkey FOREIGN KEY (dues_liability_id) REFERENCES public.dues_liabilities(id) ON DELETE RESTRICT;


--
-- Name: payment_idempotency_keys payment_idempotency_keys_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_idempotency_keys
    ADD CONSTRAINT payment_idempotency_keys_receipt_id_fkey FOREIGN KEY (receipt_id) REFERENCES public.payment_receipts(id) ON DELETE RESTRICT;


--
-- Name: payment_idempotency_keys payment_idempotency_keys_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_idempotency_keys
    ADD CONSTRAINT payment_idempotency_keys_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: payment_intents payment_intents_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_intents
    ADD CONSTRAINT payment_intents_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: payment_intents payment_intents_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_intents
    ADD CONSTRAINT payment_intents_unit_id_fkey FOREIGN KEY (unit_id) REFERENCES public.units(id) ON DELETE RESTRICT;


--
-- Name: receipt_counters receipt_counters_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_counters
    ADD CONSTRAINT receipt_counters_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: site_bank_accounts site_bank_accounts_configured_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_bank_accounts
    ADD CONSTRAINT site_bank_accounts_configured_by_fkey FOREIGN KEY (configured_by) REFERENCES public.users(id) ON DELETE SET NULL;


--
-- Name: site_bank_accounts site_bank_accounts_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.site_bank_accounts
    ADD CONSTRAINT site_bank_accounts_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: unit_occupancies unit_occupancies_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_occupancies
    ADD CONSTRAINT unit_occupancies_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.persons(id) ON DELETE RESTRICT;


--
-- Name: unit_ownerships unit_ownerships_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_ownerships
    ADD CONSTRAINT unit_ownerships_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.persons(id) ON DELETE RESTRICT;


--
-- Name: units units_house_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_house_type_id_fkey FOREIGN KEY (house_type_id) REFERENCES public.house_types(id) ON DELETE SET NULL;


--
-- Name: units units_owner_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_owner_person_id_fkey FOREIGN KEY (owner_person_id) REFERENCES public.persons(id);


--
-- Name: units units_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE RESTRICT;


--
-- Name: units units_tenant_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_tenant_person_id_fkey FOREIGN KEY (tenant_person_id) REFERENCES public.persons(id);


--
-- Name: user_site_roles user_site_roles_site_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_site_roles
    ADD CONSTRAINT user_site_roles_site_id_fkey FOREIGN KEY (site_id) REFERENCES public.sites(id) ON DELETE CASCADE;


--
-- Name: user_site_roles user_site_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_site_roles
    ADD CONSTRAINT user_site_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id) ON DELETE CASCADE;


--
-- Name: users users_person_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_person_id_fkey FOREIGN KEY (person_id) REFERENCES public.persons(id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

\unrestrict 5qygkS6aN39jOHS0yYpboxyymbkW8pK9Z7c0BSQWgypSlTeBtD7eEt04QFScxsX

