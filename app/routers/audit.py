from pathlib import Path

from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.db import flash_redirect, get_db, get_personas, resolve_actor

BASE_DIR = Path(__file__).resolve().parent.parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
templates.env.cache = None

router = APIRouter(prefix="/audit")


@router.get("", response_class=HTMLResponse)
async def audit_viewer(request: Request, msg: str = "", kind: str = "success"):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

        with conn.cursor() as cur:
            cur.execute("""
                SELECT ae.audit_event_id, ae.occurred_at, ae.action, ae.object_type, ae.object_id,
                       encode(ae.event_hash, 'hex') AS hash_hex,
                       coalesce(p.full_name, 'System Process') AS actor_name
                  FROM aud.audit_event ae
                  LEFT JOIN iam.account a ON a.account_id = ae.acting_account_id
                  LEFT JOIN iam.person p ON p.person_id = a.person_id
                 ORDER BY ae.audit_event_id DESC
                 LIMIT 40;
            """)
            events = cur.fetchall()

            cur.execute("""
                SELECT seal_id, from_event_id, to_event_id,
                       encode(seal_hash, 'hex') AS seal_hex, sealed_at
                  FROM aud.audit_seal
                 ORDER BY seal_id DESC LIMIT 5;
            """)
            seals = cur.fetchall()

            cur.execute("SELECT * FROM rpt.v_case_ageing;")
            case_ageing = cur.fetchall()

    return templates.TemplateResponse(request, "audit.html", {
        "personas": personas,
        "actor": actor,
        "events": events,
        "seals": seals,
        "case_ageing": case_ageing,
        "msg": msg,
        "kind": kind,
        "active_tab": "audit",
    })


@router.post("/seal")
async def trigger_audit_seal(actor_id: str = Form(...)):
    with get_db(actor_id) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT aud.fn_seal_audit() AS sealed_up_to;")
            res = cur.fetchone()["sealed_up_to"]
    if res:
        return flash_redirect("/audit", f"Cryptographic audit batch sealed up to Event #{res}.")
    return flash_redirect("/audit", "All current audit events are already sealed.", "info")