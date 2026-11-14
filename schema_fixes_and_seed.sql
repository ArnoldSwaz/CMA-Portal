-- =====================================================================
-- CMA Online Regulatory and Licensing Portal
-- Schema Fixes, Trigger Hardening & Multi-Category Demo Seed
-- Compatible with pgAdmin 4 Query Tool (no psql backslash meta-commands)
-- =====================================================================

BEGIN;

-- 1. Ensure session attribution is set for all seed operations
SET LOCAL app.account_id = '00000000-0000-0000-0000-000000000001';

-- =====================================================================
-- PART A: TRIGGER & BUSINESS RULE FIXES
-- =====================================================================

-- Fix 1: Safe session variable parsing + initial INSERT logging on lic.licence
CREATE OR REPLACE FUNCTION lic.fn_licence_history() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_actor uuid;
BEGIN
    v_actor := coalesce(
        nullif(current_setting('app.account_id', true), '')::uuid,
        '00000000-0000-0000-0000-000000000001'::uuid
    );

    IF TG_OP = 'INSERT' THEN
        INSERT INTO lic.licence_status_history (
            licence_id, from_status, to_status, reason, effective_date, changed_by_account_id
        ) VALUES (
            NEW.licence_id, NULL, NEW.status,
            coalesce(NEW.status_reason, 'Initial licence grant'),
            coalesce(NEW.status_effective_date, NEW.issue_date),
            v_actor
        );
        RETURN NEW;
    END IF;

    -- TG_OP = 'UPDATE'
    IF NEW.status_reason IS NULL OR NEW.status_effective_date IS NULL
       OR (NEW.status_reason IS NOT DISTINCT FROM OLD.status_reason
           AND NEW.status_effective_date IS NOT DISTINCT FROM OLD.status_effective_date) THEN
        RAISE EXCEPTION 'Licence status change requires a new reason and effective date'
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO lic.licence_status_history (
        licence_id, from_status, to_status, reason, effective_date, changed_by_account_id
    ) VALUES (
        NEW.licence_id, OLD.status, NEW.status,
        NEW.status_reason, NEW.status_effective_date, v_actor
    );
    RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_30_history_insert ON lic.licence;
CREATE TRIGGER trg_30_history_insert
    AFTER INSERT ON lic.licence
    FOR EACH ROW EXECUTE FUNCTION lic.fn_licence_history();


-- Fix 2: Protect core application attributes after submission & auto-populate expected_decision_date
CREATE OR REPLACE FUNCTION app.fn_application_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    missing text;
    v_sla_days smallint;
BEGIN
    IF OLD.submitted_at IS NOT NULL AND NEW.submitted_at IS DISTINCT FROM OLD.submitted_at THEN
        RAISE EXCEPTION 'submitted_at is immutable once set' USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.reference_number IS NOT NULL AND NEW.reference_number IS DISTINCT FROM OLD.reference_number THEN
        RAISE EXCEPTION 'reference_number is immutable once issued' USING ERRCODE = 'check_violation';
    END IF;

    -- Prevent changing category, applicant, or application type once submitted
    IF OLD.status <> 'DRAFT' THEN
        IF NEW.category_version_id IS DISTINCT FROM OLD.category_version_id
           OR NEW.applicant_entity_id IS DISTINCT FROM OLD.applicant_entity_id
           OR NEW.applicant_person_id IS DISTINCT FROM OLD.applicant_person_id
           OR NEW.application_type IS DISTINCT FROM OLD.application_type THEN
            RAISE EXCEPTION 'Core application attributes cannot be modified after submission'
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    IF OLD.status = 'DRAFT' AND NEW.status = 'SUBMITTED' THEN
        SELECT string_agg(ci.item_code, ', ' ORDER BY ci.display_order) INTO missing
          FROM cfg.checklist_item ci
         WHERE ci.category_version_id = NEW.category_version_id
           AND ci.is_mandatory
           AND NOT EXISTS (
               SELECT 1 FROM doc.document d
                 JOIN doc.document_version v ON v.document_id = d.document_id AND v.version_no = d.current_version_no
                WHERE d.application_id = NEW.application_id
                  AND d.checklist_item_id = ci.checklist_item_id
                  AND v.scan_status = 'CLEAN');
        IF missing IS NOT NULL THEN
            RAISE EXCEPTION 'Mandatory checklist documents missing: %', missing USING ERRCODE = 'check_violation';
        END IF;

        SELECT sla_target_days INTO v_sla_days
          FROM cfg.category_version
         WHERE category_version_id = NEW.category_version_id;

        NEW.submitted_at           := now();
        NEW.expected_decision_date := (current_date + coalesce(v_sla_days, 60));
        NEW.reference_number       := 'CMA/APP/' || to_char(now(), 'YYYY') || '/' ||
                                      lpad(nextval('app.application_ref_seq')::text, 6, '0');
    END IF;

    IF NEW.status IN ('APPROVED','REJECTED') AND NEW.decided_at IS NULL THEN
        NEW.decided_at := now();
    END IF;

    NEW.last_saved_at := now();
    RETURN NEW;
END $$;


-- Fix 3: Enforce role-based authorization (required_role_id) on workflow stage actions
CREATE OR REPLACE FUNCTION wf.fn_case_stage_rules() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    cur cfg.workflow_stage;
    case_version uuid;
    pending text;
    v_actor_type varchar(10);
BEGIN
    SELECT * INTO cur FROM cfg.workflow_stage WHERE workflow_stage_id = NEW.workflow_stage_id;

    SELECT a.category_version_id INTO case_version
      FROM wf.case_file c JOIN app.application a ON a.application_id = c.application_id
     WHERE c.case_id = NEW.case_id;

    IF case_version IS NOT NULL AND case_version <> cur.category_version_id THEN
        RAISE EXCEPTION 'Workflow stage does not belong to the category version of this case'
              USING ERRCODE = 'check_violation';
    END IF;

    -- Verify actor holds the required role for this stage (SYSTEM accounts exempt)
    IF NEW.actor_account_id IS NOT NULL THEN
        SELECT account_type INTO v_actor_type FROM iam.account WHERE account_id = NEW.actor_account_id;
        IF v_actor_type <> 'SYSTEM' AND NOT EXISTS (
            SELECT 1 FROM iam.account_role ar
             WHERE ar.account_id = NEW.actor_account_id
               AND ar.role_id = cur.required_role_id
               AND ar.revoked_at IS NULL
        ) THEN
            RAISE EXCEPTION 'Actor does not hold the required role for stage %', cur.stage_code
                  USING ERRCODE = 'insufficient_privilege';
        END IF;
    END IF;

    -- Sequential stage enforcement
    IF NEW.status IN ('IN_PROGRESS','COMPLETED') THEN
        SELECT string_agg(ws.stage_code, ', ' ORDER BY ws.sequence_no) INTO pending
          FROM cfg.workflow_stage ws
         WHERE ws.category_version_id = cur.category_version_id
           AND ws.is_mandatory AND ws.sequence_no < cur.sequence_no
           AND NOT EXISTS (
               SELECT 1 FROM wf.case_stage cs
                WHERE cs.case_id = NEW.case_id
                  AND cs.workflow_stage_id = ws.workflow_stage_id
                  AND cs.status = 'COMPLETED'
           );
        IF pending IS NOT NULL THEN
            RAISE EXCEPTION 'Stage % cannot start: prior mandatory stage(s) % incomplete', cur.stage_code, pending
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- Segregation of duties: Recommender cannot approve
    IF NEW.status = 'COMPLETED' AND cur.stage_code IN ('APPROVAL','COMMITTEE','BOARD') AND EXISTS (
        SELECT 1 FROM wf.case_stage cs JOIN cfg.workflow_stage ws ON ws.workflow_stage_id = cs.workflow_stage_id
         WHERE cs.case_id = NEW.case_id AND cs.status = 'COMPLETED'
           AND ws.stage_code = 'RECOMMENDATION' AND cs.actor_account_id = NEW.actor_account_id
    ) THEN
        RAISE EXCEPTION 'Segregation of duties: the recommender cannot approve the same case'
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    RETURN NEW;
END $$;


-- =====================================================================
-- PART B: DEMO PERSONAS, ENTITIES & ROLE ASSIGNMENTS
-- =====================================================================

-- Staff & Applicant Personas
INSERT INTO iam.person (person_id, full_name, national_id_type, national_id_number, nationality, date_of_birth, email_address, mobile_number, id_verification_status) VALUES
 ('10000000-0000-0000-0000-000000000001', 'Amina Wanjiru',       'NATIONAL_ID', '23456781', 'KE', '1988-04-12', 'amina@alphasec.co.ke',    '+254711000001', 'VERIFIED'),
 ('10000000-0000-0000-0000-000000000002', 'David Otieno',        'NATIONAL_ID', '30000001', 'KE', '1985-09-20', 'otieno@cma.or.ke',        '+254711000002', 'VERIFIED'),
 ('10000000-0000-0000-0000-000000000003', 'Grace Mwangi',        'NATIONAL_ID', '30000002', 'KE', '1980-02-15', 'mwangi@cma.or.ke',        '+254711000003', 'VERIFIED'),
 ('10000000-0000-0000-0000-000000000004', 'Samuel Kamau',        'NATIONAL_ID', '30000003', 'KE', '1983-11-05', 'kamau@cma.or.ke',         '+254711000004', 'VERIFIED'),
 ('10000000-0000-0000-0000-000000000005', 'Beatrice Njoroge',    'NATIONAL_ID', '30000004', 'KE', '1987-07-19', 'njoroge@cma.or.ke',       '+254711000005', 'VERIFIED'),
 ('10000000-0000-0000-0000-000000000006', 'Peter Mutua (Audit)', 'NATIONAL_ID', '30000005', 'KE', '1979-06-30', 'audit@cma.or.ke',         '+254711000006', 'VERIFIED'),
 ('10000000-0000-0000-0000-000000000007', 'Brian Kiprop',        'NATIONAL_ID', '29876543', 'KE', '1990-01-22', 'bkiprop@savannahcap.co.ke','+254722000007', 'VERIFIED')
ON CONFLICT (person_id) DO NOTHING;

-- Corporate Entities
INSERT INTO iam.entity (entity_id, registered_name, registration_number, kra_pin, entity_form, registered_office, paid_up_capital, verification_status) VALUES
 ('20000000-0000-0000-0000-000000000001', 'Alpha Securities Ltd',          'PVT-2019-0001', 'P051234567Z', 'PRIVATE_COMPANY', 'Upper Hill, Nairobi',   65000000.00, 'VERIFIED'),
 ('20000000-0000-0000-0000-000000000002', 'Savannah Capital Partners Ltd', 'PVT-2021-4410', 'P051987654K', 'PRIVATE_COMPANY', 'Westlands, Nairobi',   120000000.00, 'VERIFIED'),
 ('20000000-0000-0000-0000-000000000003', 'Rift Valley Coffee Brokers Ltd','PVT-2022-8821', 'P051456789M', 'PRIVATE_COMPANY', 'Wakima House, Nairobi', 25000000.00, 'VERIFIED')
ON CONFLICT (entity_id) DO NOTHING;

-- Accounts (Demo password placeholder: 'Demo@2026')
INSERT INTO iam.account (account_id, person_id, entity_id, account_type, password_hash, status, email_verified_at, mobile_verified_at) VALUES
 ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'CORPORATE', 'demo_hash_Demo@2026', 'ACTIVE', now(), now()),
 ('30000000-0000-0000-0000-000000000007', '10000000-0000-0000-0000-000000000007', '20000000-0000-0000-0000-000000000002', 'CORPORATE', 'demo_hash_Demo@2026', 'ACTIVE', now(), now())
ON CONFLICT (account_id) DO NOTHING;

INSERT INTO iam.account (account_id, person_id, account_type, password_hash, status) VALUES
 ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'INTERNAL', 'demo_hash_Demo@2026', 'ACTIVE'), -- Licensing Officer
 ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'INTERNAL', 'demo_hash_Demo@2026', 'ACTIVE'), -- Supervisor & Approving Manager
 ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', 'INTERNAL', 'demo_hash_Demo@2026', 'ACTIVE'), -- Legal Officer
 ('30000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000005', 'INTERNAL', 'demo_hash_Demo@2026', 'ACTIVE'), -- Supervision & Finance Officer
 ('30000000-0000-0000-0000-000000000006', '10000000-0000-0000-0000-000000000006', 'INTERNAL', 'demo_hash_Demo@2026', 'ACTIVE')  -- Auditor
ON CONFLICT (account_id) DO NOTHING;

-- Bind Roles to Accounts (Required for stage authorization!)
INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000001'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code IN ('APPLICANT_ADMIN','APPLICANT_PREPARER','APPLICANT_SUBMITTER','APPLICANT_PAYER')
ON CONFLICT DO NOTHING;

INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000007'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code IN ('APPLICANT_ADMIN','APPLICANT_PREPARER','APPLICANT_SUBMITTER','APPLICANT_PAYER')
ON CONFLICT DO NOTHING;

INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000002'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code = 'LICENSING_OFFICER'
ON CONFLICT DO NOTHING;

INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000003'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code IN ('LICENSING_SUPERVISOR','APPROVING_MANAGER','SYSTEM_ADMIN')
ON CONFLICT DO NOTHING;

INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000004'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code = 'LEGAL_OFFICER'
ON CONFLICT DO NOTHING;

INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000005'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code IN ('SUPERVISION_OFFICER','FINANCE_OFFICER')
ON CONFLICT DO NOTHING;

INSERT INTO iam.account_role (account_id, role_id, granted_by_account_id)
SELECT '30000000-0000-0000-0000-000000000006'::uuid, role_id, '00000000-0000-0000-0000-000000000001'::uuid
  FROM iam.role WHERE role_code = 'AUDITOR'
ON CONFLICT DO NOTHING;


-- =====================================================================
-- PART C: PUBLISHED VERSIONS, CHECKLISTS, FORMS, FEES & WORKFLOWS
--         ACROSS ALL 7 LICENCE CATEGORIES
-- =====================================================================

DO $$
DECLARE
    v_cat record;
    v_ver_id uuid;
    v_doc_cert uuid;
    v_doc_aud  uuid;
    v_doc_brd  uuid;
    v_doc_plan uuid;
    v_doc_cap  uuid;
    v_doc_tax  uuid;
    v_role_lo  uuid;
    v_role_leg uuid;
    v_role_mgr uuid;
    v_app_fee  numeric(14,2);
    v_lic_fee  numeric(14,2);
    v_sla      smallint;
BEGIN
    SELECT document_type_id INTO v_doc_cert FROM cfg.document_type WHERE type_code = 'CERT_INCORPORATION';
    SELECT document_type_id INTO v_doc_aud  FROM cfg.document_type WHERE type_code = 'AUDITED_ACCOUNTS';
    SELECT document_type_id INTO v_doc_brd  FROM cfg.document_type WHERE type_code = 'BOARD_RESOLUTION';
    SELECT document_type_id INTO v_doc_plan FROM cfg.document_type WHERE type_code = 'BUSINESS_PLAN';
    SELECT document_type_id INTO v_doc_cap  FROM cfg.document_type WHERE type_code = 'CAPITAL_EVIDENCE';
    SELECT document_type_id INTO v_doc_tax  FROM cfg.document_type WHERE type_code = 'TAX_COMPLIANCE';

    SELECT role_id INTO v_role_lo  FROM iam.role WHERE role_code = 'LICENSING_OFFICER';
    SELECT role_id INTO v_role_leg FROM iam.role WHERE role_code = 'LEGAL_OFFICER';
    SELECT role_id INTO v_role_mgr FROM iam.role WHERE role_code = 'APPROVING_MANAGER';

    FOR v_cat IN SELECT * FROM cfg.licence_category LOOP
        -- Skip if already published
        IF EXISTS (SELECT 1 FROM cfg.category_version WHERE category_id = v_cat.category_id AND status = 'PUBLISHED') THEN
            CONTINUE;
        END IF;

        -- Category-specific fee & SLA calibration
        CASE v_cat.category_code
            WHEN 'INVESTMENT_BANK'    THEN v_app_fee := 10000; v_lic_fee := 250000; v_sla := 60;
            WHEN 'STOCKBROKER'        THEN v_app_fee := 10000; v_lic_fee := 150000; v_sla := 60;
            WHEN 'FUND_MANAGER'       THEN v_app_fee := 10000; v_lic_fee := 100000; v_sla := 45;
            WHEN 'INVESTMENT_ADVISER' THEN v_app_fee :=  5000; v_lic_fee :=  50000; v_sla := 30;
            WHEN 'CIS'                THEN v_app_fee := 10000; v_lic_fee := 100000; v_sla := 45;
            WHEN 'ISPP'               THEN v_app_fee := 10000; v_lic_fee := 100000; v_sla := 45;
            WHEN 'COFFEE_BROKER'      THEN v_app_fee :=  5000; v_lic_fee :=  50000; v_sla := 30;
            ELSE                           v_app_fee := 10000; v_lic_fee := 100000; v_sla := 45;
        END CASE;

        INSERT INTO cfg.category_version (
            category_id, version_no, status, effective_from, sla_target_days, sla_warning_pct, created_by_account_id
        ) VALUES (
            v_cat.category_id, 1, 'PUBLISHED', '2026-01-01', v_sla, 80, '00000000-0000-0000-0000-000000000001'
        ) RETURNING category_version_id INTO v_ver_id;

        -- Standard Statutory Checklist Items (4 mandatory + 1 optional)
        INSERT INTO cfg.checklist_item (category_version_id, item_code, description, document_type_id, is_mandatory, statutory_reference, display_order) VALUES
         (v_ver_id, 'CHK-01', 'Certified Certificate of Incorporation / Registration', v_doc_cert, true,  'Cap. 485A Reg. 6(1)(a)', 1),
         (v_ver_id, 'CHK-02', 'Board Resolution authorizing CMA Licence Application',    v_doc_brd,  true,  'Cap. 485A Reg. 6(1)(b)', 2),
         (v_ver_id, 'CHK-03', 'Three-Year Business Plan & Financial Projections',        v_doc_plan, true,  'Cap. 485A Reg. 6(1)(c)', 3),
         (v_ver_id, 'CHK-04', 'Bank Confirmation of Minimum Paid-Up & Liquid Capital',   v_doc_cap,  true,  'Cap. 485A Reg. 6(1)(d)', 4),
         (v_ver_id, 'CHK-05', 'Valid KRA Tax Compliance Certificate',                    v_doc_tax,  false, 'Cap. 485A Reg. 6(2)',    5);

        -- Dynamic Application Form Fields
        INSERT INTO cfg.form_field (category_version_id, field_code, label, data_type, is_mandatory, min_value, choice_values, display_order) VALUES
         (v_ver_id, 'PROPOSED_COMMENCEMENT', 'Proposed Date of Commencement of Operations', 'DATE',   true,  NULL, NULL, 1),
         (v_ver_id, 'AUDITOR_FIRM_NAME',     'External Audit Firm Name',                    'TEXT',   true,  NULL, NULL, 2),
         (v_ver_id, 'LIQUID_CAPITAL_KES',    'Current Liquid Capital Balance (KES)',        'NUMBER', true,  0,    NULL, 3),
         (v_ver_id, 'TARGET_CLIENT_SEGMENT', 'Primary Target Investor Segment',             'CHOICE', true,  NULL, ARRAY['RETAIL_INVESTORS','INSTITUTIONAL_INVESTORS','HIGH_NET_WORTH','ALL_SEGMENTS'], 4);

        -- Fee Schedules (NEW Application, NEW Licence, RENEWAL)
        INSERT INTO cfg.fee_schedule (category_version_id, application_type, fee_type, calculation_basis, fixed_amount, late_penalty_percent, invoice_lead_days) VALUES
         (v_ver_id, 'NEW',     'APPLICATION', 'FIXED', v_app_fee, 0,  14),
         (v_ver_id, 'NEW',     'LICENCE',     'FIXED', v_lic_fee, 0,  14),
         (v_ver_id, 'RENEWAL', 'RENEWAL',     'FIXED', v_lic_fee, 10, 30);

        -- 4-Stage Approval Workflow
        INSERT INTO cfg.workflow_stage (category_version_id, stage_code, sequence_no, is_mandatory, required_role_id) VALUES
         (v_ver_id, 'REVIEW',          1, true, v_role_lo),
         (v_ver_id, 'RECOMMENDATION',  2, true, v_role_lo),
         (v_ver_id, 'LEGAL_CLEARANCE', 3, true, v_role_leg),
         (v_ver_id, 'APPROVAL',        4, true, v_role_mgr);

        -- Dedicated Queue per Category
        INSERT INTO wf.queue (queue_name, queue_kind, category_id, supervisor_account_id)
        VALUES (v_cat.category_name || ' Queue', 'APPLICATION', v_cat.category_id, '30000000-0000-0000-0000-000000000003')
        ON CONFLICT (category_id) DO NOTHING;
    END LOOP;
END $$;

-- Supervision Exceptions Queue
INSERT INTO wf.queue (queue_id, queue_name, queue_kind, supervisor_account_id)
VALUES ('44000000-0000-0000-0000-000000000099', 'Market Supervision & Compliance Queue', 'COMPLIANCE', '30000000-0000-0000-0000-000000000003')
ON CONFLICT (queue_name) DO NOTHING;

-- Assign Officers to Queues
INSERT INTO wf.queue_member (queue_id, account_id, competence_level, is_active)
SELECT queue_id, '30000000-0000-0000-0000-000000000002'::uuid, 3, true
  FROM wf.queue WHERE queue_kind = 'APPLICATION'
ON CONFLICT DO NOTHING;

INSERT INTO wf.queue_member (queue_id, account_id, competence_level, is_active)
VALUES ('44000000-0000-0000-0000-000000000099', '30000000-0000-0000-0000-000000000005', 3, true)
ON CONFLICT DO NOTHING;


-- =====================================================================
-- PART D: REGULATORY RETURNS, NOTIFICATION TEMPLATES & INITIAL REGISTER
-- =====================================================================

-- Periodic Return Type + Validation Rule
INSERT INTO cfg.return_type (return_type_id, return_code, return_name, is_quantitative, frequency, days_after_period_end)
VALUES ('45000000-0000-0000-0000-000000000001', 'LIQ_CAPITAL_M', 'Monthly Capital Adequacy & Liquid Capital Return', true, 'MONTHLY', 10)
ON CONFLICT (return_code) DO NOTHING;

INSERT INTO cfg.return_template_field (template_field_id, return_type_id, field_code, label, data_type, is_mandatory, display_order) VALUES
 ('46000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', 'LIQUID_CAPITAL',      'Liquid Capital (KES)',             'NUMBER', true, 1),
 ('46000000-0000-0000-0000-000000000002', '45000000-0000-0000-0000-000000000001', 'MIN_REQUIRED_CAPITAL','Minimum Required Capital (KES)',   'NUMBER', true, 2),
 ('46000000-0000-0000-0000-000000000003', '45000000-0000-0000-0000-000000000001', 'COMPLIANCE_NOTES',    'Capital Adequacy Commentary',      'TEXT',   false,3)
ON CONFLICT (return_type_id, field_code) DO NOTHING;

INSERT INTO cfg.validation_rule (validation_rule_id, return_type_id, rule_code, rule_kind, expression, failure_message, on_failure)
VALUES ('47000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001', 'MIN_LIQ_CAP', 'THRESHOLD', 'LIQUID_CAPITAL >= 30000000', 'Liquid capital reported is below the statutory KES 30,000,000 threshold.', 'EXCEPTION')
ON CONFLICT (return_type_id, rule_code) DO NOTHING;

-- Notification Templates
INSERT INTO cfg.notification_template (event_type, channel, version_no, subject, body, is_statutory, is_active) VALUES
 ('APPLICATION_SUBMITTED', 'EMAIL', 1, 'CMA Application Received: {{reference_number}}', 'Dear {{applicant_name}}, your application {{reference_number}} has been received. Please settle invoice {{invoice_number}} to initiate review.', false, true),
 ('PAYMENT_CONFIRMED',     'EMAIL', 1, 'Payment Receipt: {{receipt_number}}',            'Payment of KES {{amount}} for {{reference_number}} has been confirmed. Case {{case_number}} is now assigned for review.', false, true),
 ('QUERY_RAISED',          'EMAIL', 1, 'Action Required: Regulatory Query on {{reference_number}}', 'A formal query has been raised on your application. Please respond by {{due_date}}.', true, true),
 ('LICENCE_ISSUED',        'EMAIL', 1, 'CMA Licence Granted: {{licence_number}}',        'Congratulations {{applicant_name}}. Licence {{licence_number}} has been granted and published on the CMA Public Register.', true, true)
ON CONFLICT (event_type, channel, version_no) DO NOTHING;

-- Seed 2 Active Public Register Licences so the Public Register & QR Verification work immediately
INSERT INTO lic.licence (licence_id, licence_number, holder_entity_id, category_id, issue_date, expiry_date, status, conditions, published_at)
SELECT '90000000-0000-0000-0000-000000000001', 'CMA/IB/2026/0042', '20000000-0000-0000-0000-000000000002', category_id,
       '2026-03-01', '2027-02-28', 'ACTIVE', 'Subject to quarterly capital adequacy reporting under Reg. 24.', now()
  FROM cfg.licence_category WHERE category_code = 'INVESTMENT_BANK'
ON CONFLICT (licence_id) DO NOTHING;

INSERT INTO lic.certificate (licence_id, verification_code, signature_value, signing_key_ref, storage_key, delivered_at)
VALUES ('90000000-0000-0000-0000-000000000001', 'VC-8842-K9LP', 'MEUCIQDx92aSimulatedSignatureHash==', 'hsm:cma-seal-2026', 's3://cma-certs/CMA-IB-2026-0042.pdf', now())
ON CONFLICT (licence_id, certificate_version) DO NOTHING;

INSERT INTO lic.licence (licence_id, licence_number, holder_entity_id, category_id, issue_date, expiry_date, status, conditions, published_at)
SELECT '90000000-0000-0000-0000-000000000002', 'CMA/CB/2026/0019', '20000000-0000-0000-0000-000000000003', category_id,
       '2026-05-15', '2027-05-14', 'ACTIVE', 'Authorized to trade on the Nairobi Coffee Exchange.', now()
  FROM cfg.licence_category WHERE category_code = 'COFFEE_BROKER'
ON CONFLICT (licence_id) DO NOTHING;

INSERT INTO lic.certificate (licence_id, verification_code, signature_value, signing_key_ref, storage_key, delivered_at)
VALUES ('90000000-0000-0000-0000-000000000002', 'VC-1904-RVCB', 'MEUCIQDz71bSimulatedSignatureHash==', 'hsm:cma-seal-2026', 's3://cma-certs/CMA-CB-2026-0019.pdf', now())
ON CONFLICT (licence_id, certificate_version) DO NOTHING;

-- Seed an Upcoming Filing Obligation for Savannah Capital Partners Ltd
INSERT INTO cmp.filing_obligation (obligation_id, licence_id, return_type_id, period_start, period_end, due_date, status)
VALUES ('48000000-0000-0000-0000-000000000001', '90000000-0000-0000-0000-000000000001', '45000000-0000-0000-0000-000000000001',
        '2026-10-01', '2026-10-31', '2026-11-20', 'UPCOMING')
ON CONFLICT (licence_id, return_type_id, period_end) DO NOTHING;

-- Seal the initial audit log batch
SELECT aud.fn_seal_audit();

COMMIT;