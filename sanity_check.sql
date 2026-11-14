SELECT * FROM lic.v_public_register;
SELECT * FROM lic.fn_verify_certificate('VC-8842-K9LP');
SELECT count(*) AS audit_events FROM aud.audit_event;