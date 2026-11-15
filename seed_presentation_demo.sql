-- CMA-ORLP Presentation Demo Patch (100% Schema-Matched & Idempotent)
-- Populates APP-2026-0001, P22 (Key Person Fit & Proper), and P27 (Filing Calendar & Compliance Exceptions)

BEGIN;

DO $$
DECLARE
    v_actor_id       uuid;
    v_applicant_acct uuid;
    v_officer_acct   uuid;
    v_cat_ver_id     uuid;
    v_fee_sched_id   uuid;
    v_fee_amount     numeric(14,2);
    v_app_id         uuid := '30000000-0000-0000-0000-000000000001';
    v_lic_id         uuid;
    v_queue_id       uuid;
    v_p1             uuid := '40000000-0000-0000-0000-000000000001';
    v_p2             uuid := '40000000-0000-0000-0000-000000000002';
    v_p3             uuid := '40000000-0000-0000-0000-000000000003';
    v_rt_capital     uuid;
    v_rt_quarterly   uuid;
    v_rt_client      uuid;
    v_rt_aml         uuid;
    v_today          date := current_date;
    v_m_start        date := date_trunc('month', current_date)::date;
    v_m_end          date := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
BEGIN
    -- 1. Set session actor for aud.fn_capture_change audit triggers
    SELECT account_id INTO v_actor_id FROM iam.account WHERE status = 'ACTIVE' LIMIT 1;
    IF v_actor_id IS NOT NULL THEN
        PERFORM set_config('app.account_id', v_actor_id::text, true);
    END IF;

    SELECT account_id INTO v_applicant_acct
      FROM iam.account
     WHERE person_id = '10000000-0000-0000-0000-000000000001'
     LIMIT 1;
    v_applicant_acct := COALESCE(v_applicant_acct, v_actor_id);

    SELECT account_id INTO v_officer_acct
      FROM iam.account
     WHERE person_id = '10000000-0000-0000-0000-000000000002'
     LIMIT 1;

    -- 2. Seed primary demo application (APP-2026-0001) + Paid Fee + Open Review Case
    SELECT cv.category_version_id INTO v_cat_ver_id
      FROM cfg.category_version cv
      JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
     WHERE lc.category_code = 'FUND_MANAGER'
     LIMIT 1;

    IF v_cat_ver_id IS NULL THEN
        SELECT category_version_id INTO v_cat_ver_id FROM cfg.category_version LIMIT 1;
    END IF;

    SELECT q.queue_id INTO v_queue_id
      FROM wf.queue q
      JOIN cfg.category_version cv ON cv.category_version_id = v_cat_ver_id
      JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
     WHERE q.queue_name = lc.category_name || ' Queue';
    IF v_queue_id IS NULL THEN
        SELECT queue_id INTO v_queue_id FROM wf.queue LIMIT 1;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM app.application WHERE reference_number = 'APP-2026-0001') THEN
        INSERT INTO app.application (
            application_id, reference_number, applicant_entity_id,
            category_version_id, application_type, status,
            created_by_account_id, submitted_by_account_id,
            created_at, last_saved_at, submitted_at, expected_decision_date
        ) VALUES (
            v_app_id, 'APP-2026-0001', '20000000-0000-0000-0000-000000000001',
            v_cat_ver_id, 'ADDITIONAL_CATEGORY', 'PAID',
            v_applicant_acct, v_applicant_acct,
            now() - interval '4 days', now() - interval '3 days',
            now() - interval '3 days', current_date + 45
        );

        SELECT fee_schedule_id, COALESCE(fixed_amount, 50000.00)
          INTO v_fee_sched_id, v_fee_amount
          FROM cfg.fee_schedule
         LIMIT 1;

        IF v_fee_sched_id IS NOT NULL THEN
            INSERT INTO fin.fee (
                fee_id, application_id, fee_schedule_id, fee_type,
                amount, currency, payment_reference, status, due_date, paid_at
            ) VALUES (
                '31000000-0000-0000-0000-000000000001', v_app_id, v_fee_sched_id, 'APPLICATION',
                GREATEST(v_fee_amount, 1000.00), 'KES', 'MPESA-Q89K2L9P10', 'PAID',
                current_date + 7, now() - interval '3 days'
            ) ON CONFLICT (fee_id) DO NOTHING;
        END IF;

        IF v_queue_id IS NOT NULL THEN
            INSERT INTO wf.case_file (
                case_id, case_number, case_type, application_id,
                queue_id, assigned_officer_id, status, sla_due_at
            ) VALUES (
                '32000000-0000-0000-0000-000000000001', 'CASE/2026/000101', 'APPLICATION', v_app_id,
                v_queue_id, v_officer_acct, 'OPEN', now() + interval '42 days'
            ) ON CONFLICT (case_id) DO NOTHING;
        END IF;

        UPDATE app.application
           SET status = 'UNDER_REVIEW'
         WHERE application_id = v_app_id;
    ELSE
        SELECT application_id INTO v_app_id
          FROM app.application
         WHERE reference_number = 'APP-2026-0001'
         LIMIT 1;
    END IF;

    -- 3. Seed Key Person Declarations for P22
    INSERT INTO iam.person (
        person_id, full_name, national_id_type, national_id_number,
        nationality, email_address, mobile_number, id_verification_status
    ) VALUES
        (v_p1, 'Amina Wanjiru', 'NATIONAL_ID', '28491034', 'KE',
         'amina.wanjiru@alphasecurities.co.ke', '+254712345001', 'VERIFIED'),
        (v_p2, 'David Kiprop',  'NATIONAL_ID', '24109876', 'KE',
         'david.kiprop@alphasecurities.co.ke', '+254712345002', 'VERIFIED'),
        (v_p3, 'Grace Muthoni', 'NATIONAL_ID', '30918273', 'KE',
         'grace.muthoni@alphasecurities.co.ke', '+254712345003', 'VERIFIED')
    ON CONFLICT (person_id) DO NOTHING;

    INSERT INTO app.key_person_declaration (
        declaration_id, application_id, person_id, key_person_role,
        shareholding_percent, has_criminal_conviction, has_been_bankrupt,
        has_regulatory_sanction, is_disqualified_director,
        disclosure_notes, confirmed_by_applicant, fit_proper_outcome
    ) VALUES
        ('41000000-0000-0000-0000-000000000001', v_app_id, v_p1, 'CHIEF_EXECUTIVE',
         35.00, false, false, false, false,
         '12 years investment management experience; CRB & DCI Good Conduct verified.',
         true, 'PENDING'),
        ('41000000-0000-0000-0000-000000000002', v_app_id, v_p2, 'COMPLIANCE_OFFICER',
         5.00, false, false, false, false,
         'CISI & ICPAK member in good standing; clean regulatory history.',
         true, 'PENDING'),
        ('41000000-0000-0000-0000-000000000003', v_app_id, v_p3, 'DIRECTOR',
         20.00, false, false, true, false,
         'Disclosed 2021 administrative warning at prior brokerage firm; remediation clearance attached.',
         true, 'PENDING')
    ON CONFLICT (declaration_id) DO NOTHING;

    -- 4. Seed Return Types in cfg.return_type
    INSERT INTO cfg.return_type (
        return_type_id, return_code, return_name, is_quantitative, frequency, days_after_period_end
    ) VALUES
        ('50000000-0000-0000-0000-000000000001', 'RET-CAP-M', 'Monthly Net Capital Adequacy Return', true, 'MONTHLY', 15),
        ('50000000-0000-0000-0000-000000000002', 'RET-FIN-Q', 'Quarterly Unaudited Financial Statements', true, 'QUARTERLY', 30),
        ('50000000-0000-0000-0000-000000000003', 'RET-CLI-M', 'Client Assets & Segregated Accounts Return', true, 'MONTHLY', 10),
        ('50000000-0000-0000-0000-000000000004', 'RET-AML-Q', 'AML/CFT Suspicious Transaction Summary', false, 'QUARTERLY', 20)
    ON CONFLICT (return_code) DO NOTHING;

    SELECT return_type_id INTO v_rt_capital   FROM cfg.return_type WHERE return_code = 'RET-CAP-M';
    SELECT return_type_id INTO v_rt_quarterly FROM cfg.return_type WHERE return_code = 'RET-FIN-Q';
    SELECT return_type_id INTO v_rt_client    FROM cfg.return_type WHERE return_code = 'RET-CLI-M';
    SELECT return_type_id INTO v_rt_aml       FROM cfg.return_type WHERE return_code = 'RET-AML-Q';

    -- 5. Seed Filing Obligations & Compliance Exceptions for P27
    SELECT licence_id INTO v_lic_id FROM lic.licence LIMIT 1;

    IF v_lic_id IS NOT NULL THEN
        INSERT INTO cmp.filing_obligation (
            obligation_id, licence_id, return_type_id, period_start, period_end, due_date, status
        ) VALUES
            ('51000000-0000-0000-0000-000000000001', v_lic_id, v_rt_capital,
             (v_m_start - interval '2 months')::date, (v_m_start - interval '1 month - 1 day')::date,
             GREATEST((v_m_start - interval '1 month - 1 day')::date, v_today - 14), 'OVERDUE'),
            ('51000000-0000-0000-0000-000000000002', v_lic_id, v_rt_client,
             (v_m_start - interval '2 months')::date, (v_m_start - interval '1 month - 1 day')::date,
             GREATEST((v_m_start - interval '1 month - 1 day')::date, v_today - 9), 'OVERDUE'),
            ('51000000-0000-0000-0000-000000000003', v_lic_id, v_rt_quarterly,
             (v_m_start - interval '3 months')::date, (v_m_start - interval '1 day')::date,
             GREATEST((v_m_start - interval '1 day')::date, v_today - 5), 'OVERDUE'),
            ('51000000-0000-0000-0000-000000000004', v_lic_id, v_rt_aml,
             (v_m_start - interval '3 months')::date, (v_m_start - interval '1 day')::date,
             GREATEST((v_m_start - interval '1 day')::date, v_today - 2), 'FILED'),
            ('51000000-0000-0000-0000-000000000005', v_lic_id, v_rt_capital,
             v_m_start, LEAST(v_m_end, v_today + 2), v_today + 3, 'UPCOMING'),
            ('51000000-0000-0000-0000-000000000006', v_lic_id, v_rt_client,
             v_m_start, LEAST(v_m_end, v_today + 5), v_today + 6, 'UPCOMING'),
            ('51000000-0000-0000-0000-000000000007', v_lic_id, v_rt_quarterly,
             v_m_start, LEAST(v_m_end, v_today + 10), v_today + 12, 'UPCOMING'),
            ('51000000-0000-0000-0000-000000000008', v_lic_id, v_rt_aml,
             v_m_start, LEAST(v_m_end, v_today + 15), v_today + 18, 'UPCOMING')
        ON CONFLICT (obligation_id) DO NOTHING;

        INSERT INTO cmp.compliance_exception (
            exception_id, licence_id, obligation_id, exception_type, details, status, raised_at
        ) VALUES
            ('52000000-0000-0000-0000-000000000001', v_lic_id, '51000000-0000-0000-0000-000000000001',
             'LATE_FILING',
             'Monthly Net Capital Adequacy Return is 14 days past statutory deadline (Capital Markets Licensing & General Regs).',
             'OPEN', now() - interval '14 days'),
            ('52000000-0000-0000-0000-000000000002', v_lic_id, '51000000-0000-0000-0000-000000000002',
             'LATE_FILING',
             'Client Assets & Segregated Accounts Return is 9 days overdue; custodial reconciliation pending.',
             'OPEN', now() - interval '9 days'),
            ('52000000-0000-0000-0000-000000000003', v_lic_id, '51000000-0000-0000-0000-000000000003',
             'LATE_FILING',
             'Quarterly Unaudited Financial Statements are 5 days overdue pending external auditor sign-off.',
             'UNDER_REVIEW', now() - interval '5 days'),
            ('52000000-0000-0000-0000-000000000004', v_lic_id, '51000000-0000-0000-0000-000000000001',
             'LATE_FILING',
             'Prior period liquid capital schedule addendum overdue by 3 days.',
             'OPEN', now() - interval '3 days'),
            ('52000000-0000-0000-0000-000000000005', v_lic_id, '51000000-0000-0000-0000-000000000004',
             'LATE_FILING',
             'AML/CFT quarterly return filed 1 day after grace window; MLRO attestation verified.',
             'UNDER_REVIEW', now() - interval '1 day')
        ON CONFLICT (exception_id) DO NOTHING;

        IF v_queue_id IS NOT NULL THEN
            INSERT INTO wf.case_file (
                case_id, case_type, compliance_exception_id, queue_id, status, sla_due_at
            ) VALUES (
                '53000000-0000-0000-0000-000000000001',
                'COMPLIANCE',
                '52000000-0000-0000-0000-000000000001',
                v_queue_id,
                'OPEN',
                now() + interval '5 days'
            )
            ON CONFLICT (compliance_exception_id) DO NOTHING;
        END IF;
    END IF;
END $$;

COMMIT;