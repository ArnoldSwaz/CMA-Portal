from fastapi import FastAPI, Form
from fastapi.responses import RedirectResponse

from app.db import flash_redirect, get_db
from app.routers import applicant, audit, public, staff

app = FastAPI(title="CMA Online Regulatory & Licensing Portal")


@app.post("/switch-actor")
async def switch_actor(actor_id: str = Form(...), next_url: str = Form("/")):
    resp = RedirectResponse(url=next_url or "/", status_code=303)
    resp.set_cookie("actor_id", actor_id, httponly=True)
    return resp


@app.post("/reset-demo")
async def reset_demo():
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                TRUNCATE TABLE
                    wf.decision,
                    wf.case_stage,
                    wf.case_query,
                    wf.case_file,
                    fin.receipt,
                    fin.payment,
                    fin.fee,
                    doc.document_version,
                    doc.document,
                    app.application_field_value,
                    app.application,
                    cmp.compliance_exception,
                    cmp.return_value,
                    cmp.regulatory_return
                CASCADE;

                DELETE FROM lic.certificate WHERE licence_id NOT IN (
                    '90000000-0000-0000-0000-000000000001',
                    '90000000-0000-0000-0000-000000000002'
                );
                DELETE FROM lic.licence WHERE licence_id NOT IN (
                    '90000000-0000-0000-0000-000000000001',
                    '90000000-0000-0000-0000-000000000002'
                );
                UPDATE cmp.filing_obligation SET status = 'UPCOMING'
                 WHERE obligation_id = '48000000-0000-0000-0000-000000000001';
            """)
    return flash_redirect("/", "Demo database reset to clean initial seed state.")


app.include_router(public.router)
app.include_router(applicant.router)
app.include_router(staff.router)
app.include_router(audit.router)