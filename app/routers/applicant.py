import hashlib
import secrets
from pathlib import Path
from typing import Optional

import psycopg
from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.db import flash_redirect, get_db, get_personas, resolve_actor

BASE_DIR = Path(__file__).resolve().parent.parent
UPLOAD_DIR = BASE_DIR.parent / "uploads"
UPLOAD_DIR.mkdir(exist_ok=True)

templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
templates.env.cache = None

router = APIRouter(prefix="/applicant")


@router.get("", response_class=HTMLResponse)
async def applicant_portal(
    request: Request,
    app_id: Optional[str] = None,
    msg: str = "",
    kind: str = "success",
):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

        # Default to a corporate applicant if an internal staff user is currently selected
        applicant_actor = actor if actor["account_type"] == "CORPORATE" else next(
            (p for p in personas if p["account_type"] == "CORPORATE"), actor
        )
        entity_id = applicant_actor["entity_id"]

        with conn.cursor() as cur:
            cur.execute("""
                SELECT lc.category_id::text, lc.category_code, lc.category_name,
                       cv.category_version_id::text, cv.sla_target_days,
                       fs.fixed_amount AS app_fee
                  FROM cfg.licence_category lc
                  JOIN cfg.category_version cv ON cv.category_id = lc.category_id AND cv.status = 'PUBLISHED'
                  LEFT JOIN cfg.fee_schedule fs ON fs.category_version_id = cv.category_version_id
                                               AND fs.application_type = 'NEW' AND fs.fee_type = 'APPLICATION'
                 ORDER BY lc.category_name;
            """)
            available_categories = cur.fetchall()

            cur.execute("""
                SELECT a.application_id::text, a.reference_number, a.application_type, a.status,
                       a.created_at, a.submitted_at, a.expected_decision_date, a.decided_at,
                       lc.category_name, cv.category_version_id::text,
                       f.fee_id::text, f.invoice_number, f.amount AS fee_amount, f.status AS fee_status,
                       f.payment_reference,
                       cf.case_id::text, cf.case_number, cf.status AS case_status
                  FROM app.application a
                  JOIN cfg.category_version cv ON cv.category_version_id = a.category_version_id
                  JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
                  LEFT JOIN fin.fee f ON f.application_id = a.application_id AND f.fee_type = 'APPLICATION'
                  LEFT JOIN wf.case_file cf ON cf.application_id = a.application_id
                 WHERE a.applicant_entity_id = %s
                 ORDER BY a.created_at DESC;
            """, (entity_id,))
            applications = cur.fetchall()

            selected_app = None
            form_fields = []
            checklist = []
            queries = []

            target_app_id = app_id or (applications[0]["application_id"] if applications else None)
            if target_app_id:
                selected_app = next((a for a in applications if a["application_id"] == target_app_id), None)

            if selected_app:
                cur.execute("""
                    SELECT ff.form_field_id::text, ff.field_code, ff.label, ff.data_type,
                           ff.is_mandatory, ff.choice_values, afv.value_text
                      FROM cfg.form_field ff
                      LEFT JOIN app.application_field_value afv
                        ON afv.form_field_id = ff.form_field_id AND afv.application_id = %s
                     WHERE ff.category_version_id = %s
                     ORDER BY ff.display_order;
                """, (selected_app["application_id"], selected_app["category_version_id"]))
                form_fields = cur.fetchall()

                cur.execute("""
                    SELECT ci.checklist_item_id::text, ci.item_code, ci.description,
                           ci.is_mandatory, ci.statutory_reference,
                           d.document_id::text, d.review_status, d.review_comment,
                           dv.file_name, dv.scan_status
                      FROM cfg.checklist_item ci
                      LEFT JOIN doc.document d
                        ON d.checklist_item_id = ci.checklist_item_id AND d.application_id = %s
                      LEFT JOIN doc.document_version dv
                        ON dv.document_id = d.document_id AND dv.version_no = d.current_version_no
                     WHERE ci.category_version_id = %s
                     ORDER BY ci.display_order;
                """, (selected_app["application_id"], selected_app["category_version_id"]))
                checklist = cur.fetchall()

                if selected_app["case_id"]:
                    cur.execute("""
                        SELECT query_id::text, non_compliance_details, response_due_date,
                               status, response_text, raised_at
                          FROM wf.case_query
                         WHERE case_id = %s
                         ORDER BY raised_at DESC;
                    """, (selected_app["case_id"],))
                    queries = cur.fetchall()

            cur.execute("""
                SELECT l.licence_id::text, l.licence_number, lc.category_name, l.status,
                       l.issue_date, l.expiry_date, ce.verification_code
                  FROM lic.licence l
                  JOIN cfg.licence_category lc ON lc.category_id = l.category_id
                  LEFT JOIN lic.certificate ce ON ce.licence_id = l.licence_id AND ce.is_current = true
                 WHERE l.holder_entity_id = %s
                 ORDER BY l.issue_date DESC;
            """, (entity_id,))
            entity_licences = cur.fetchall()

            cur.execute("""
                SELECT o.obligation_id::text, o.licence_id::text, l.licence_number,
                       rt.return_type_id::text, rt.return_name, o.period_start, o.period_end,
                       o.due_date, o.status
                  FROM cmp.filing_obligation o
                  JOIN lic.licence l ON l.licence_id = o.licence_id
                  JOIN cfg.return_type rt ON rt.return_type_id = o.return_type_id
                 WHERE l.holder_entity_id = %s
                 ORDER BY o.due_date ASC;
            """, (entity_id,))
            obligations = cur.fetchall()

    return templates.TemplateResponse(request, "applicant.html", {
        "personas": personas,
        "actor": actor,
        "applicant_actor": applicant_actor,
        "available_categories": available_categories,
        "applications": applications,
        "selected_app": selected_app,
        "form_fields": form_fields,
        "checklist": checklist,
        "queries": queries,
        "entity_licences": entity_licences,
        "obligations": obligations,
        "msg": msg,
        "kind": kind,
        "active_tab": "applicant",
    })


@router.post("/create-draft")
async def create_draft(
    request: Request,
    category_version_id: str = Form(...),
    application_type: str = Form("NEW"),
):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)
        applicant_actor = actor if actor["account_type"] == "CORPORATE" else next(
            (p for p in personas if p["account_type"] == "CORPORATE"), actor
        )

    try:
        with get_db(applicant_actor["account_id"]) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO app.application (
                        applicant_entity_id, category_version_id, application_type, created_by_account_id
                    ) VALUES (%s, %s, %s, %s)
                    RETURNING application_id::text;
                """, (
                    applicant_actor["entity_id"],
                    category_version_id,
                    application_type,
                    applicant_actor["account_id"],
                ))
                new_id = cur.fetchone()["application_id"]
        return flash_redirect(f"/applicant?app_id={new_id}", "Draft application created.")
    except psycopg.Error as e:
        return flash_redirect("/applicant", f"Blocked: {e.diag.message_primary or str(e)}", "error")


@router.post("/save-fields")
async def save_fields(request: Request):
    form = await request.form()
    application_id = form.get("application_id")
    actor_id = form.get("actor_id")

    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                for key, val in form.items():
                    if key.startswith("field_"):
                        field_id = key.replace("field_", "")
                        cur.execute("""
                            INSERT INTO app.application_field_value (application_id, form_field_id, value_text)
                            VALUES (%s, %s, %s)
                            ON CONFLICT (application_id, form_field_id)
                            DO UPDATE SET value_text = EXCLUDED.value_text, updated_at = now();
                        """, (application_id, field_id, str(val)))
        return flash_redirect(f"/applicant?app_id={application_id}", "Application form particulars saved.")
    except psycopg.Error as e:
        return flash_redirect(f"/applicant?app_id={application_id}", f"Error: {e.diag.message_primary or str(e)}", "error")


@router.post("/upload-doc")
async def upload_doc(
    application_id: str = Form(...),
    checklist_item_id: str = Form(...),
    actor_id: str = Form(...),
    entity_id: str = Form(...),
    file: UploadFile = File(...),
):
    content = await file.read()
    if not content:
        return flash_redirect(f"/applicant?app_id={application_id}", "Please select a non-empty file.", "error")

    sha256 = hashlib.sha256(content).hexdigest()
    safe_name = f"{secrets.token_hex(6)}_{Path(file.filename).name}"
    dest = UPLOAD_DIR / safe_name
    dest.write_bytes(content)

    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT document_type_id FROM cfg.checklist_item WHERE checklist_item_id = %s;",
                    (checklist_item_id,),
                )
                doc_type_id = cur.fetchone()["document_type_id"]

                cur.execute("""
                    SELECT document_id, current_version_no
                      FROM doc.document
                     WHERE application_id = %s AND checklist_item_id = %s;
                """, (application_id, checklist_item_id))
                existing = cur.fetchone()

                if existing:
                    next_ver = existing["current_version_no"] + 1
                    doc_id = existing["document_id"]
                    cur.execute("""
                        UPDATE doc.document
                           SET current_version_no = %s, review_status = 'PENDING', review_comment = NULL
                         WHERE document_id = %s;
                    """, (next_ver, doc_id))
                else:
                    next_ver = 1
                    cur.execute("""
                        INSERT INTO doc.document (
                            application_id, entity_id, checklist_item_id, document_type_id, current_version_no
                        ) VALUES (%s, %s, %s, %s, 1)
                        RETURNING document_id;
                    """, (application_id, entity_id, checklist_item_id, doc_type_id))
                    doc_id = cur.fetchone()["document_id"]

                cur.execute("""
                    INSERT INTO doc.document_version (
                        document_id, version_no, storage_key, file_name, mime_type,
                        size_bytes, sha256_hash, scan_status, scanned_at, uploaded_by_account_id
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, 'CLEAN', now(), %s);
                """, (
                    doc_id, next_ver, str(dest), file.filename,
                    file.content_type or "application/pdf", len(content), sha256, actor_id,
                ))
        return flash_redirect(f"/applicant?app_id={application_id}", f"Uploaded '{file.filename}' (Scan: CLEAN).")
    except psycopg.Error as e:
        return flash_redirect(f"/applicant?app_id={application_id}", f"Upload error: {e.diag.message_primary or str(e)}", "error")


@router.post("/submit")
async def submit_application(application_id: str = Form(...), actor_id: str = Form(...)):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                # DB trigger enforces BR-08 (all mandatory checklist docs CLEAN)
                cur.execute("""
                    UPDATE app.application
                       SET status = 'SUBMITTED', submitted_by_account_id = %s
                     WHERE application_id = %s
                    RETURNING reference_number, category_version_id;
                """, (actor_id, application_id))
                row = cur.fetchone()
                ref_no = row["reference_number"]

                cur.execute("""
                    SELECT fee_schedule_id, fixed_amount
                      FROM cfg.fee_schedule
                     WHERE category_version_id = %s AND application_type = 'NEW' AND fee_type = 'APPLICATION';
                """, (row["category_version_id"],))
                fs = cur.fetchone()
                pay_ref = f"ECIT-{secrets.token_hex(4).upper()}"
                cur.execute("""
                    INSERT INTO fin.fee (
                        application_id, fee_schedule_id, fee_type, amount, payment_reference, due_date
                    ) VALUES (%s, %s, 'APPLICATION', %s, %s, current_date + 14)
                    RETURNING invoice_number;
                """, (application_id, fs["fee_schedule_id"], fs["fixed_amount"], pay_ref))
                inv_no = cur.fetchone()["invoice_number"]

        return flash_redirect(
            f"/applicant?app_id={application_id}",
            f"Submitted! Reference {ref_no} issued and Invoice {inv_no} generated.",
        )
    except psycopg.Error as e:
        return flash_redirect(
            f"/applicant?app_id={application_id}",
            f"Submission Blocked by Database Rule: {e.diag.message_primary or str(e)}",
            "error",
        )


@router.post("/pay-fee")
async def pay_fee(
    application_id: str = Form(...),
    fee_id: str = Form(...),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT * FROM fin.fee WHERE fee_id = %s;", (fee_id,))
                fee = cur.fetchone()

                ext_tx = f"MPESA-{secrets.token_hex(5).upper()}"
                cur.execute("""
                    INSERT INTO fin.payment (
                        fee_id, source, external_transaction_id, payment_reference,
                        amount, payer_account_id, status, match_status, settled_at
                    ) VALUES (%s, 'GATEWAY', %s, %s, %s, %s, 'SETTLED', 'MATCHED', now())
                    RETURNING payment_id;
                """, (fee_id, ext_tx, fee["payment_reference"], fee["amount"], actor_id))
                pay_id = cur.fetchone()["payment_id"]

                cur.execute("UPDATE fin.fee SET status = 'PAID', paid_at = now() WHERE fee_id = %s;", (fee_id,))
                rct_no = f"RCT/2026/{secrets.randbelow(9000000)+1000000}"
                cur.execute("INSERT INTO fin.receipt (receipt_number, payment_id) VALUES (%s, %s);", (rct_no, pay_id))

                cur.execute("""
                    UPDATE app.application SET status = 'PAID' WHERE application_id = %s
                    RETURNING category_version_id;
                """, (application_id,))
                cv_id = cur.fetchone()["category_version_id"]

                cur.execute("""
                    SELECT q.queue_id, cv.sla_target_days
                      FROM cfg.category_version cv
                      JOIN wf.queue q ON q.category_id = cv.category_id
                     WHERE cv.category_version_id = %s;
                """, (cv_id,))
                q_row = cur.fetchone()

                cur.execute("""
                    SELECT account_id FROM wf.queue_member
                     WHERE queue_id = %s AND is_active = true LIMIT 1;
                """, (q_row["queue_id"],))
                officer = cur.fetchone()
                officer_id = officer["account_id"] if officer else None

                cur.execute("""
                    INSERT INTO wf.case_file (
                        case_type, application_id, queue_id, assigned_officer_id, sla_due_at
                    ) VALUES ('APPLICATION', %s, %s, %s, now() + (%s || ' days')::interval)
                    RETURNING case_number;
                """, (application_id, q_row["queue_id"], officer_id, q_row["sla_target_days"]))
                case_no = cur.fetchone()["case_number"]

                cur.execute("UPDATE app.application SET status = 'UNDER_REVIEW' WHERE application_id = %s;", (application_id,))

        return flash_redirect(
            f"/applicant?app_id={application_id}",
            f"Payment settled ({rct_no})! Case {case_no} opened and routed to CMA Licensing.",
        )
    except psycopg.Error as e:
        return flash_redirect(f"/applicant?app_id={application_id}", f"Payment error: {e.diag.message_primary or str(e)}", "error")


@router.post("/respond-query")
async def respond_query(
    application_id: str = Form(...),
    case_id: str = Form(...),
    query_id: str = Form(...),
    response_text: str = Form(...),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE wf.case_query
                       SET status = 'RESPONDED', response_text = %s,
                           responded_by_account_id = %s, responded_at = now()
                     WHERE query_id = %s;
                """, (response_text, actor_id, query_id))

                cur.execute("UPDATE wf.case_file SET status = 'OPEN' WHERE case_id = %s;", (case_id,))
                cur.execute("UPDATE app.application SET status = 'UNDER_REVIEW' WHERE application_id = %s;", (application_id,))

        return flash_redirect(f"/applicant?app_id={application_id}", "Response submitted. Case reopened and SLA clock resumed.")
    except psycopg.Error as e:
        return flash_redirect(f"/applicant?app_id={application_id}", f"Error: {e.diag.message_primary or str(e)}", "error")


@router.post("/file-return")
async def file_return(
    obligation_id: str = Form(...),
    licence_id: str = Form(...),
    return_type_id: str = Form(...),
    due_date: str = Form(...),
    liquid_capital: float = Form(...),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                passed = liquid_capital >= 30000000
                v_status = "PASSED" if passed else "FAILED"

                cur.execute("""
                    INSERT INTO cmp.regulatory_return (
                        licence_id, return_type_id, obligation_id, filing_kind,
                        due_date, filed_by_account_id, validation_status
                    ) VALUES (%s, %s, %s, 'PERIODIC', %s, %s, %s)
                    RETURNING return_id;
                """, (licence_id, return_type_id, obligation_id, due_date, actor_id, v_status))
                ret_id = cur.fetchone()["return_id"]

                cur.execute("""
                    INSERT INTO cmp.return_value (return_id, template_field_id, value_numeric)
                    VALUES (%s, '46000000-0000-0000-0000-000000000001', %s);
                """, (ret_id, liquid_capital))

                cur.execute("UPDATE cmp.filing_obligation SET status = 'FILED' WHERE obligation_id = %s;", (obligation_id,))

                if not passed:
                    cur.execute("""
                        INSERT INTO cmp.compliance_exception (
                            licence_id, obligation_id, return_id, exception_type, details
                        ) VALUES (%s, %s, %s, 'THRESHOLD_BREACH', %s)
                        RETURNING exception_id;
                    """, (
                        licence_id, obligation_id, ret_id,
                        f"Reported liquid capital KES {liquid_capital:,.2f} is below the KES 30,000,000 minimum.",
                    ))
                    exc_id = cur.fetchone()["exception_id"]

                    cur.execute("""
                        INSERT INTO wf.case_file (
                            case_type, compliance_exception_id, queue_id, assigned_officer_id, sla_due_at
                        ) VALUES ('COMPLIANCE', %s, '44000000-0000-0000-0000-000000000099',
                                  '30000000-0000-0000-0000-000000000005', now() + interval '14 days');
                    """, (exc_id,))
                    return flash_redirect(
                        "/applicant",
                        "Return filed, BUT triggered a Capital Threshold Breach exception and Supervision Case!",
                        "error",
                    )

        return flash_redirect("/applicant", "Periodic Liquid Capital Return filed and passed validation.")
    except psycopg.Error as e:
        return flash_redirect("/applicant", f"Filing error: {e.diag.message_primary or str(e)}", "error")