import secrets
from pathlib import Path
from typing import Optional

import psycopg
from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.db import flash_redirect, get_db, get_personas, resolve_actor

BASE_DIR = Path(__file__).resolve().parent.parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
templates.env.cache = None

router = APIRouter(prefix="/staff")


@router.get("", response_class=HTMLResponse)
async def staff_workspace(
    request: Request,
    case_id: Optional[str] = None,
    msg: str = "",
    kind: str = "success",
):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

        with conn.cursor() as cur:
            cur.execute("""
                SELECT cf.case_id::text, cf.case_number, cf.case_type, cf.status,
                       cf.opened_at, cf.sla_due_at, cf.sla_clock_resumed_at,
                       q.queue_name, p_off.full_name AS officer_name,
                       a.application_id::text, a.reference_number, a.status AS app_status,
                       a.category_version_id::text,
                       coalesce(e.registered_name, ce_e.registered_name) AS entity_name,
                       coalesce(lc.category_name, 'Compliance Supervision') AS category_name,
                       ce.details AS exception_details
                  FROM wf.case_file cf
                  JOIN wf.queue q ON q.queue_id = cf.queue_id
                  LEFT JOIN iam.account acc_off ON acc_off.account_id = cf.assigned_officer_id
                  LEFT JOIN iam.person p_off ON p_off.person_id = acc_off.person_id
                  LEFT JOIN app.application a ON a.application_id = cf.application_id
                  LEFT JOIN iam.entity e ON e.entity_id = a.applicant_entity_id
                  LEFT JOIN cfg.category_version cv ON cv.category_version_id = a.category_version_id
                  LEFT JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
                  LEFT JOIN cmp.compliance_exception ce ON ce.exception_id = cf.compliance_exception_id
                  LEFT JOIN lic.licence ce_l ON ce_l.licence_id = ce.licence_id
                  LEFT JOIN iam.entity ce_e ON ce_e.entity_id = ce_l.holder_entity_id
                 ORDER BY cf.opened_at DESC;
            """)
            cases = cur.fetchall()

            selected_case = None
            stages = []
            case_docs = []
            field_values = []
            decision = None

            target_case_id = case_id or (cases[0]["case_id"] if cases else None)
            if target_case_id:
                selected_case = next((c for c in cases if c["case_id"] == target_case_id), None)

            if selected_case:
                if selected_case["category_version_id"]:
                    cur.execute("""
                        SELECT ws.workflow_stage_id::text, ws.stage_code, ws.sequence_no,
                               r.role_code AS required_role,
                               cs.status AS stage_status, cs.outcome,
                               cs.remarks, p_act.full_name AS actor_name
                          FROM cfg.workflow_stage ws
                          JOIN iam.role r ON r.role_id = ws.required_role_id
                          LEFT JOIN wf.case_stage cs
                            ON cs.workflow_stage_id = ws.workflow_stage_id AND cs.case_id = %s
                          LEFT JOIN iam.account acc_act ON acc_act.account_id = cs.actor_account_id
                          LEFT JOIN iam.person p_act ON p_act.person_id = acc_act.person_id
                         WHERE ws.category_version_id = %s
                         ORDER BY ws.sequence_no;
                    """, (selected_case["case_id"], selected_case["category_version_id"]))
                    stages = cur.fetchall()

                if selected_case["application_id"]:
                    cur.execute("""
                        SELECT d.document_id::text, ci.item_code, ci.description,
                               d.review_status, d.review_comment, dv.file_name
                          FROM doc.document d
                          JOIN cfg.checklist_item ci ON ci.checklist_item_id = d.checklist_item_id
                          JOIN doc.document_version dv ON dv.document_id = d.document_id AND dv.version_no = d.current_version_no
                         WHERE d.application_id = %s
                         ORDER BY ci.display_order;
                    """, (selected_case["application_id"],))
                    case_docs = cur.fetchall()

                    cur.execute("""
                        SELECT ff.label, afv.value_text
                          FROM app.application_field_value afv
                          JOIN cfg.form_field ff ON ff.form_field_id = afv.form_field_id
                         WHERE afv.application_id = %s
                         ORDER BY ff.display_order;
                    """, (selected_case["application_id"],))
                    field_values = cur.fetchall()

                cur.execute("""
                    SELECT d.*, p.full_name AS decision_maker_name
                      FROM wf.decision d
                      JOIN iam.account a ON a.account_id = d.decision_maker_account_id
                      JOIN iam.person p ON p.person_id = a.person_id
                     WHERE d.case_id = %s;
                """, (selected_case["case_id"],))
                decision = cur.fetchone()

            cur.execute("""
                SELECT l.licence_id::text, l.licence_number, e.registered_name AS holder_name,
                       lc.category_name, l.status, l.expiry_date
                  FROM lic.licence l
                  JOIN iam.entity e ON e.entity_id = l.holder_entity_id
                  JOIN cfg.licence_category lc ON lc.category_id = l.category_id
                 ORDER BY l.created_at DESC;
            """)
            all_licences = cur.fetchall()

    return templates.TemplateResponse(request, "staff.html", {
        "personas": personas,
        "actor": actor,
        "cases": cases,
        "selected_case": selected_case,
        "stages": stages,
        "case_docs": case_docs,
        "field_values": field_values,
        "decision": decision,
        "all_licences": all_licences,
        "msg": msg,
        "kind": kind,
        "active_tab": "staff",
    })


@router.post("/review-doc")
async def review_doc(
    case_id: str = Form(...),
    document_id: str = Form(...),
    review_status: str = Form(...),
    review_comment: str = Form(""),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE doc.document
                       SET review_status = %s,
                           review_comment = nullif(%s, ''),
                           reviewed_by_account_id = %s,
                           reviewed_at = now()
                     WHERE document_id = %s;
                """, (review_status, review_comment.strip(), actor_id, document_id))
        return flash_redirect(f"/staff?case_id={case_id}", f"Document marked as {review_status}.")
    except psycopg.Error as e:
        return flash_redirect(f"/staff?case_id={case_id}", f"Blocked: {e.diag.message_primary or str(e)}", "error")


@router.post("/raise-query")
async def raise_query(
    case_id: str = Form(...),
    application_id: str = Form(...),
    details: str = Form(...),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO wf.case_query (case_id, raised_by_account_id, non_compliance_details, response_due_date)
                    VALUES (%s, %s, %s, current_date + 14);
                """, (case_id, actor_id, details))

                cur.execute("UPDATE wf.case_file SET status = 'AWAITING_APPLICANT' WHERE case_id = %s;", (case_id,))
                if application_id:
                    cur.execute("UPDATE app.application SET status = 'AWAITING_APPLICANT' WHERE application_id = %s;", (application_id,))

        return flash_redirect(f"/staff?case_id={case_id}", "Query sent to applicant. SLA clock automatically paused.")
    except psycopg.Error as e:
        return flash_redirect(f"/staff?case_id={case_id}", f"Error: {e.diag.message_primary or str(e)}", "error")


@router.post("/complete-stage")
async def complete_stage(
    case_id: str = Form(...),
    workflow_stage_id: str = Form(...),
    outcome: str = Form(...),
    remarks: str = Form(""),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO wf.case_stage (
                        case_id, workflow_stage_id, status, outcome, actor_account_id, remarks, started_at, completed_at
                    ) VALUES (%s, %s, 'COMPLETED', %s, %s, nullif(%s, ''), now(), now())
                    ON CONFLICT (case_id, workflow_stage_id, attempt_no)
                    DO UPDATE SET status = 'COMPLETED', outcome = EXCLUDED.outcome,
                                  actor_account_id = EXCLUDED.actor_account_id,
                                  remarks = EXCLUDED.remarks, completed_at = now();
                """, (case_id, workflow_stage_id, outcome, actor_id, remarks.strip()))
        return flash_redirect(f"/staff?case_id={case_id}", f"Stage completed with outcome: {outcome}.")
    except psycopg.Error as e:
        return flash_redirect(
            f"/staff?case_id={case_id}",
            f"Database Rule Enforcement: {e.diag.message_primary or str(e)}",
            "error",
        )


@router.post("/record-decision")
async def record_decision(
    case_id: str = Form(...),
    application_id: str = Form(""),
    outcome: str = Form(...),
    basis: str = Form(...),
    conditions_imposed: str = Form(""),
    rejection_reason: str = Form(""),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO wf.decision (
                        case_id, outcome, decision_maker_account_id, authority_level,
                        basis, conditions_imposed, rejection_reason
                    ) VALUES (%s, %s, %s, 'MANAGEMENT', %s, nullif(%s, ''), nullif(%s, ''))
                    RETURNING decision_id;
                """, (case_id, outcome, actor_id, basis, conditions_imposed.strip(), rejection_reason.strip()))
                dec_id = cur.fetchone()["decision_id"]

                cur.execute("UPDATE wf.case_file SET status = 'CLOSED' WHERE case_id = %s;", (case_id,))

                if application_id and outcome in ("APPROVED", "REJECTED"):
                    cur.execute("UPDATE app.application SET status = %s WHERE application_id = %s;", (outcome, application_id))

                if application_id and outcome == "APPROVED":
                    cur.execute("""
                        SELECT a.applicant_entity_id, cv.category_id, lc.category_code, lc.validity_months
                          FROM app.application a
                          JOIN cfg.category_version cv ON cv.category_version_id = a.category_version_id
                          JOIN cfg.licence_category lc ON lc.category_id = cv.category_id
                         WHERE a.application_id = %s;
                    """, (application_id,))
                    app_info = cur.fetchone()
                    lic_no = f"CMA/{app_info['category_code'][:3]}/2026/{secrets.randbelow(9000)+1000}"
                    ver_code = f"VC-{secrets.token_hex(2).upper()}-{secrets.token_hex(2).upper()}"

                    cur.execute("""
                        INSERT INTO lic.licence (
                            licence_number, holder_entity_id, category_id, issuing_decision_id,
                            issue_date, expiry_date, status, conditions, published_at
                        ) VALUES (%s, %s, %s, %s, current_date, current_date + (%s || ' months')::interval,
                                  'ACTIVE', nullif(%s, ''), now())
                        RETURNING licence_id;
                    """, (
                        lic_no, app_info["applicant_entity_id"], app_info["category_id"],
                        dec_id, app_info["validity_months"], conditions_imposed.strip(),
                    ))
                    lic_id = cur.fetchone()["licence_id"]

                    cur.execute("""
                        INSERT INTO lic.certificate (
                            licence_id, verification_code, signature_value, signing_key_ref, storage_key, delivered_at
                        ) VALUES (%s, %s, %s, 'hsm:cma-seal-2026', %s, now());
                    """, (
                        lic_id, ver_code,
                        f"MEUCIQD{secrets.token_hex(16)}==",
                        f"s3://cma-certs/{lic_no.replace('/', '-')}.pdf",
                    ))
                    return flash_redirect(
                        f"/staff?case_id={case_id}",
                        f"APPROVED! Licence {lic_no} (Verify Code: {ver_code}) published to Public Register!",
                    )

        return flash_redirect(f"/staff?case_id={case_id}", f"Final decision recorded: {outcome}.")
    except psycopg.Error as e:
        return flash_redirect(
            f"/staff?case_id={case_id}",
            f"Decision Blocked: {e.diag.message_primary or str(e)}",
            "error",
        )


@router.post("/licence-status")
async def change_licence_status(
    licence_id: str = Form(...),
    new_status: str = Form(...),
    reason: str = Form(...),
    actor_id: str = Form(...),
):
    try:
        with get_db(actor_id) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE lic.licence
                       SET status = %s,
                           status_reason = nullif(%s, ''),
                           status_effective_date = current_date
                     WHERE licence_id = %s;
                """, (new_status, reason.strip(), licence_id))
        return flash_redirect("/staff", f"Licence status updated to {new_status} and logged to history.")
    except psycopg.Error as e:
        return flash_redirect("/staff", f"Database Rule Blocked Change: {e.diag.message_primary or str(e)}", "error")