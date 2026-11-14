\set ON_ERROR_STOP on
SET app.account_id = '00000000-0000-0000-0000-000000000001';

CREATE OR REPLACE FUNCTION pg_temp.expect_fail(label text, stmt text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE stmt;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'PASS  %  -> rejected: %', label, SQLERRM;
        RETURN;
    END;
    RAISE EXCEPTION 'FAIL  % was accepted', label;
END $$;

-- ---------- actors ----------
INSERT INTO iam.person (person_id, full_name, national_id_number, email_address, mobile_number) VALUES
 ('10000000-0000-0000-0000-000000000001','Amina Wanjiru','23456781','amina@alphasec.co.ke','+254711000001'),
 ('10000000-0000-0000-0000-000000000002','Officer Otieno','30000001','otieno@cma.or.ke','+254711000002'),
 ('10000000-0000-0000-0000-000000000003','Manager Mwangi','30000002','mwangi@cma.or.ke','+254711000003'),
 ('10000000-0000-0000-0000-000000000004','Legal Kamau','30000003','kamau@cma.or.ke','+254711000004');
INSERT INTO iam.entity (entity_id, registered_name, registration_number, kra_pin, entity_form, registered_office, paid_up_capital)
VALUES ('20000000-0000-0000-0000-000000000001','Alpha Securities Ltd','PVT-2019-0001','P051234567Z','PRIVATE_COMPANY','Nairobi',50000000);

SELECT pg_temp.expect_fail('Account cannot be ACTIVE before e-mail and SMS codes are confirmed (SRS-FR-M1-01)',
 $q$INSERT INTO iam.account (person_id, entity_id, account_type, password_hash, status)
    VALUES ('10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','CORPORATE','x','ACTIVE')$q$);

INSERT INTO iam.account (account_id, person_id, entity_id, account_type, password_hash, status, email_verified_at, mobile_verified_at) VALUES
 ('30000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','CORPORATE','argon2id$demo','ACTIVE',now(),now());
INSERT INTO iam.account (account_id, person_id, account_type, status) VALUES
 ('30000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','INTERNAL','ACTIVE'),
 ('30000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','INTERNAL','ACTIVE'),
 ('30000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004','INTERNAL','ACTIVE');

-- ---------- configuration: stockbroker v1 ----------
INSERT INTO cfg.category_version (category_version_id, category_id, version_no, status, effective_from, sla_target_days, created_by_account_id)
SELECT '40000000-0000-0000-0000-000000000001', category_id, 1, 'PUBLISHED', '2026-01-01', 60, '00000000-0000-0000-0000-000000000001'
  FROM cfg.licence_category WHERE category_code = 'STOCKBROKER';
INSERT INTO cfg.checklist_item (checklist_item_id, category_version_id, item_code, description, document_type_id, display_order)
SELECT '41000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','CHK-01','Audited accounts',document_type_id,1
  FROM cfg.document_type WHERE type_code='AUDITED_ACCOUNTS';
INSERT INTO cfg.workflow_stage (workflow_stage_id, category_version_id, stage_code, sequence_no, required_role_id)
SELECT v.id::uuid, '40000000-0000-0000-0000-000000000001', v.code, v.seq, r.role_id
  FROM (VALUES ('42000000-0000-0000-0000-000000000001','REVIEW',1,'LICENSING_OFFICER'),
               ('42000000-0000-0000-0000-000000000002','RECOMMENDATION',2,'LICENSING_OFFICER'),
               ('42000000-0000-0000-0000-000000000003','LEGAL_CLEARANCE',3,'LEGAL_OFFICER'),
               ('42000000-0000-0000-0000-000000000004','APPROVAL',4,'APPROVING_MANAGER')) v(id,code,seq,role)
  JOIN iam.role r ON r.role_code = v.role;
INSERT INTO cfg.fee_schedule (fee_schedule_id, category_version_id, application_type, fee_type, calculation_basis, fixed_amount)
VALUES ('43000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','NEW','APPLICATION','FIXED',100000);
INSERT INTO wf.queue (queue_id, queue_name, queue_kind, category_id, supervisor_account_id)
SELECT '44000000-0000-0000-0000-000000000001','Stockbroker licensing','APPLICATION',category_id,'30000000-0000-0000-0000-000000000003'
  FROM cfg.licence_category WHERE category_code='STOCKBROKER';

-- ---------- application ----------
INSERT INTO app.application (application_id, applicant_entity_id, category_version_id, application_type, created_by_account_id)
VALUES ('50000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','40000000-0000-0000-0000-000000000001','NEW','30000000-0000-0000-0000-000000000001');

SELECT pg_temp.expect_fail('Submission blocked while a mandatory checklist document is missing (BR-08)',
 $q$UPDATE app.application SET status='SUBMITTED' WHERE application_id='50000000-0000-0000-0000-000000000001'$q$);

INSERT INTO doc.document (document_id, application_id, entity_id, checklist_item_id, document_type_id)
SELECT '60000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001',
       '41000000-0000-0000-0000-000000000001', document_type_id FROM cfg.document_type WHERE type_code='AUDITED_ACCOUNTS';
INSERT INTO doc.document_version (document_id, version_no, storage_key, file_name, mime_type, size_bytes, sha256_hash, scan_status, uploaded_by_account_id)
VALUES ('60000000-0000-0000-0000-000000000001',1,'s3://docs/abc','accounts.pdf','application/pdf',1024,repeat('a',64),'CLEAN','30000000-0000-0000-0000-000000000001');

SELECT pg_temp.expect_fail('Rejected document needs a reviewer comment (SRS-FR-M3-04)',
 $q$UPDATE doc.document SET review_status='REJECTED' WHERE document_id='60000000-0000-0000-0000-000000000001'$q$);

UPDATE app.application SET status='SUBMITTED', submitted_by_account_id='30000000-0000-0000-0000-000000000001'
 WHERE application_id='50000000-0000-0000-0000-000000000001';
SELECT 'Reference issued: ' || reference_number || ' at ' || to_char(submitted_at,'YYYY-MM-DD HH24:MI') AS result
  FROM app.application WHERE application_id='50000000-0000-0000-0000-000000000001';

SELECT pg_temp.expect_fail('Reference number immutable after issue (SRS-FR-M2-06)',
 $q$UPDATE app.application SET reference_number='X' WHERE application_id='50000000-0000-0000-0000-000000000001'$q$);
SELECT pg_temp.expect_fail('Case cannot open before payment (BRU-02)',
 $q$INSERT INTO wf.case_file (case_type, application_id, queue_id, sla_due_at)
    VALUES ('APPLICATION','50000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000001', now()+interval '60 days')$q$);

-- ---------- fee and payment ----------
INSERT INTO fin.fee (fee_id, application_id, fee_schedule_id, fee_type, amount, payment_reference, due_date)
VALUES ('70000000-0000-0000-0000-000000000001','50000000-0000-0000-0000-000000000001','43000000-0000-0000-0000-000000000001','APPLICATION',100000,'PAY-0001',current_date+14);
INSERT INTO fin.payment (payment_id, fee_id, source, external_transaction_id, payment_reference, amount, status, match_status, settled_at)
VALUES ('71000000-0000-0000-0000-000000000001','70000000-0000-0000-0000-000000000001','GATEWAY','ECIT-998877','PAY-0001',100000,'SETTLED','MATCHED',now());
SELECT pg_temp.expect_fail('Duplicate settlement callback is idempotent (SRS-FR-M5-03)',
 $q$INSERT INTO fin.payment (fee_id, source, external_transaction_id, payment_reference, amount, status, match_status, settled_at)
    VALUES ('70000000-0000-0000-0000-000000000001','GATEWAY','ECIT-998877','PAY-0001',100000,'SETTLED','MATCHED',now())$q$);
UPDATE fin.fee SET status='PAID', paid_at=now() WHERE fee_id='70000000-0000-0000-0000-000000000001';
INSERT INTO fin.receipt (receipt_number, payment_id) VALUES ('RCT/2026/0000001','71000000-0000-0000-0000-000000000001');
UPDATE app.application SET status='PAID' WHERE application_id='50000000-0000-0000-0000-000000000001';

SELECT pg_temp.expect_fail('Illegal state jump PAID -> APPROVED (state machine)',
 $q$UPDATE app.application SET status='APPROVED' WHERE application_id='50000000-0000-0000-0000-000000000001'$q$);

-- ---------- case ----------
INSERT INTO wf.case_file (case_id, case_type, application_id, queue_id, assigned_officer_id, sla_due_at)
VALUES ('80000000-0000-0000-0000-000000000001','APPLICATION','50000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002', now()+interval '60 days');
UPDATE app.application SET status='UNDER_REVIEW' WHERE application_id='50000000-0000-0000-0000-000000000001';

SELECT pg_temp.expect_fail('Approval cannot start before review/recommendation/legal (SRS-FR-M4-04)',
 $q$INSERT INTO wf.case_stage (case_id, workflow_stage_id, status, started_at)
    VALUES ('80000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000004','IN_PROGRESS',now())$q$);

INSERT INTO wf.case_query (case_id, raised_by_account_id, non_compliance_details, response_due_date)
VALUES ('80000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000002','Board resolution not signed',current_date+14);
UPDATE wf.case_file SET status='AWAITING_APPLICANT' WHERE case_id='80000000-0000-0000-0000-000000000001';
SELECT 'SLA clock stopped: resumed_at is ' || coalesce(sla_clock_resumed_at::text,'NULL') AS result FROM wf.case_file WHERE case_id='80000000-0000-0000-0000-000000000001';
UPDATE wf.case_file SET status='OPEN' WHERE case_id='80000000-0000-0000-0000-000000000001';

INSERT INTO wf.case_stage (case_id, workflow_stage_id, status, outcome, actor_account_id, started_at, completed_at) VALUES
 ('80000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000001','COMPLETED','REVIEWED','30000000-0000-0000-0000-000000000002',now(),now());
INSERT INTO wf.case_stage (case_id, workflow_stage_id, status, outcome, actor_account_id, started_at, completed_at) VALUES
 ('80000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000002','COMPLETED','RECOMMEND_APPROVE','30000000-0000-0000-0000-000000000002',now(),now());
INSERT INTO wf.case_stage (case_id, workflow_stage_id, status, outcome, actor_account_id, started_at, completed_at) VALUES
 ('80000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000003','COMPLETED','CLEARED','30000000-0000-0000-0000-000000000004',now(),now());

SELECT pg_temp.expect_fail('Recommender cannot approve the same case (BR-04, SRS-FR-M1-06)',
 $q$INSERT INTO wf.case_stage (case_id, workflow_stage_id, status, outcome, actor_account_id, started_at, completed_at)
    VALUES ('80000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000004','COMPLETED','APPROVE','30000000-0000-0000-0000-000000000002',now(),now())$q$);
SELECT pg_temp.expect_fail('Case cannot close without a decision record (SRS-FR-M4-07)',
 $q$UPDATE wf.case_file SET status='CLOSED' WHERE case_id='80000000-0000-0000-0000-000000000001'$q$);

INSERT INTO wf.case_stage (case_id, workflow_stage_id, status, outcome, actor_account_id, started_at, completed_at) VALUES
 ('80000000-0000-0000-0000-000000000001','42000000-0000-0000-0000-000000000004','COMPLETED','APPROVE','30000000-0000-0000-0000-000000000003',now(),now());
SELECT pg_temp.expect_fail('Rejection without reasons (BR-20)',
 $q$INSERT INTO wf.decision (case_id, outcome, decision_maker_account_id, authority_level, basis)
    VALUES ('80000000-0000-0000-0000-000000000001','REJECTED','30000000-0000-0000-0000-000000000003','MANAGEMENT','x')$q$);
INSERT INTO wf.decision (decision_id, case_id, outcome, decision_maker_account_id, authority_level, basis, conditions_imposed)
VALUES ('81000000-0000-0000-0000-000000000001','80000000-0000-0000-0000-000000000001','APPROVED','30000000-0000-0000-0000-000000000003','MANAGEMENT','All statutory requirements met','Maintain minimum liquid capital');
UPDATE wf.case_file SET status='CLOSED' WHERE case_id='80000000-0000-0000-0000-000000000001';
UPDATE app.application SET status='APPROVED' WHERE application_id='50000000-0000-0000-0000-000000000001';

-- ---------- licence, certificate, register ----------
INSERT INTO lic.licence (licence_id, licence_number, holder_entity_id, category_id, issuing_decision_id, issue_date, expiry_date, conditions, published_at)
SELECT '90000000-0000-0000-0000-000000000001','CMA/SB/2026/001','20000000-0000-0000-0000-000000000001',category_id,'81000000-0000-0000-0000-000000000001',
       current_date, current_date + 365, 'Maintain minimum liquid capital', now()
  FROM cfg.licence_category WHERE category_code='STOCKBROKER';
INSERT INTO lic.certificate (licence_id, verification_code, signature_value, signing_key_ref, storage_key)
VALUES ('90000000-0000-0000-0000-000000000001','VC-7Q2X-91LM','MEUCIQ...','hsm:cma-seal-2026','s3://certs/sb-001.pdf');
SELECT 'Register: ' || licence_number || ' | ' || holder_name || ' | ' || licence_status AS result FROM lic.v_public_register;
SELECT 'Verify VC-7Q2X-91LM: ' || licence_number || ' ' || licence_status AS result FROM lic.fn_verify_certificate('VC-7Q2X-91LM');

SELECT pg_temp.expect_fail('Licence status change without reason (BR-26)',
 $q$UPDATE lic.licence SET status='SUSPENDED' WHERE licence_id='90000000-0000-0000-0000-000000000001'$q$);
UPDATE lic.licence SET status='SUSPENDED', status_reason='Capital below minimum', status_effective_date=current_date
 WHERE licence_id='90000000-0000-0000-0000-000000000001';
SELECT 'History: ' || from_status || ' -> ' || to_status || ' (' || reason || ')' AS result FROM lic.licence_status_history;
SELECT pg_temp.expect_fail('Revoked/lapsed transitions only via state table: SUSPENDED -> LAPSED',
 $q$UPDATE lic.licence SET status='LAPSED', status_reason='x', status_effective_date=current_date+1 WHERE licence_id='90000000-0000-0000-0000-000000000001'$q$);
UPDATE lic.licence SET status='ACTIVE', status_reason='Capital restored', status_effective_date=current_date+1
 WHERE licence_id='90000000-0000-0000-0000-000000000001';

-- ---------- returns and compliance ----------
INSERT INTO cfg.return_type (return_type_id, return_code, return_name, is_quantitative, frequency, days_after_period_end)
VALUES ('45000000-0000-0000-0000-000000000001','LIQ_CAPITAL_M','Monthly liquid capital return',true,'MONTHLY',10);
INSERT INTO cfg.return_template_field (template_field_id, return_type_id, field_code, label, data_type, display_order)
VALUES ('46000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','LIQUID_CAPITAL','Liquid capital (KES)','NUMBER',1);
INSERT INTO cfg.validation_rule (validation_rule_id, return_type_id, rule_code, rule_kind, expression, failure_message, on_failure)
VALUES ('47000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','MIN_LIQ','THRESHOLD','LIQUID_CAPITAL >= 30000000','Liquid capital below KES 30m','EXCEPTION');
INSERT INTO cmp.filing_obligation (obligation_id, licence_id, return_type_id, period_start, period_end, due_date)
VALUES ('48000000-0000-0000-0000-000000000001','90000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','2026-10-01','2026-10-31','2026-11-10');
INSERT INTO cmp.regulatory_return (return_id, licence_id, return_type_id, obligation_id, filing_kind, due_date, filed_by_account_id, validation_status)
VALUES ('49000000-0000-0000-0000-000000000001','90000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','48000000-0000-0000-0000-000000000001','PERIODIC','2026-11-10','30000000-0000-0000-0000-000000000001','PASSED');
INSERT INTO cmp.return_value (return_id, template_field_id, value_numeric) VALUES ('49000000-0000-0000-0000-000000000001','46000000-0000-0000-0000-000000000001',25000000);
INSERT INTO cmp.return_validation_result (return_id, validation_rule_id, passed, message) VALUES ('49000000-0000-0000-0000-000000000001','47000000-0000-0000-0000-000000000001',false,'Liquid capital below KES 30m');
INSERT INTO cmp.compliance_exception (exception_id, licence_id, return_id, exception_type, details)
VALUES ('4a000000-0000-0000-0000-000000000001','90000000-0000-0000-0000-000000000001','49000000-0000-0000-0000-000000000001','THRESHOLD_BREACH','Liquid capital KES 25m < 30m');
INSERT INTO wf.queue (queue_id, queue_name, queue_kind, supervisor_account_id)
VALUES ('44000000-0000-0000-0000-000000000002','Supervision exceptions','COMPLIANCE','30000000-0000-0000-0000-000000000003');
INSERT INTO wf.case_file (case_type, compliance_exception_id, queue_id, sla_due_at)
VALUES ('COMPLIANCE','4a000000-0000-0000-0000-000000000001','44000000-0000-0000-0000-000000000002', now()+interval '14 days');
SELECT pg_temp.expect_fail('Ad hoc disclosure must not claim a calendar obligation',
 $q$INSERT INTO cmp.regulatory_return (licence_id, return_type_id, obligation_id, filing_kind, filed_by_account_id)
    VALUES ('90000000-0000-0000-0000-000000000001','45000000-0000-0000-0000-000000000001','48000000-0000-0000-0000-000000000001','AD_HOC_DISCLOSURE','30000000-0000-0000-0000-000000000001')$q$);
SELECT 'Compliance history: filed=' || returns_filed || ', exceptions=' || exceptions_total AS result FROM cmp.v_compliance_history;

-- ---------- audit ----------
SELECT pg_temp.expect_fail('Audit events cannot be altered (NFR-05)', $q$UPDATE aud.audit_event SET action='X'$q$);
SELECT pg_temp.expect_fail('Audit events cannot be deleted (SRS-FR-M4-08)', $q$DELETE FROM aud.audit_event$q$);
SELECT pg_temp.expect_fail('Audit store cannot be truncated', $q$TRUNCATE aud.audit_event$q$);
SELECT pg_temp.expect_fail('Unattributed change refused (fail closed)',
 $q$DO $d$ BEGIN PERFORM set_config('app.account_id','',true); UPDATE iam.entity SET registered_office='Mombasa'; END $d$$q$);
SELECT 'Audit events captured: ' || count(*) || ', distinct tables: ' || count(DISTINCT object_type) AS result FROM aud.audit_event;
SELECT 'Password hash leaked into audit: ' || count(*) AS result FROM aud.audit_event WHERE after_value ? 'password_hash';
SELECT 'Seal up to event ' || aud.fn_seal_audit() AS result;
