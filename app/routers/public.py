from pathlib import Path
from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.db import get_db, get_personas, resolve_actor

BASE_DIR = Path(__file__).resolve().parent.parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
templates.env.cache = None

router = APIRouter()


@router.get("/", response_class=HTMLResponse)
async def command_hub(request: Request, msg: str = "", kind: str = "success"):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

        with conn.cursor() as cur:
            cur.execute("""
                SELECT
                  (SELECT count(*) FROM lic.licence WHERE status = 'ACTIVE') AS active_licences,
                  (SELECT count(*) FROM app.application) AS total_apps,
                  (SELECT count(*) FROM wf.case_file WHERE status <> 'CLOSED') AS open_cases,
                  (SELECT count(*) FROM aud.audit_event) AS audit_count;
            """)
            stats = cur.fetchone()

    return templates.TemplateResponse(request, "hub.html", {
        "personas": personas,
        "actor": actor,
        "stats": stats,
        "msg": msg,
        "kind": kind,
        "active_tab": "hub",
    })


@router.get("/register", response_class=HTMLResponse)
async def public_portal(
    request: Request,
    q: str = "",
    category: str = "",
    verify_code: str = "",
    msg: str = "",
    kind: str = "success",
):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

        with conn.cursor() as cur:
            cur.execute("SELECT category_code, category_name FROM cfg.licence_category ORDER BY category_name;")
            categories = cur.fetchall()

            sql = "SELECT * FROM lic.v_public_register WHERE 1=1"
            params = []
            if q.strip():
                sql += " AND (holder_name ILIKE %s OR licence_number ILIKE %s)"
                params.extend([f"%{q.strip()}%", f"%{q.strip()}%"])
            if category.strip():
                sql += " AND category_code = %s"
                params.append(category.strip())
            sql += " ORDER BY published_at DESC;"
            cur.execute(sql, params)
            licences = cur.fetchall()

            verify_result = None
            verify_searched = False
            if verify_code.strip():
                verify_searched = True
                cur.execute("SELECT * FROM lic.fn_verify_certificate(%s);", (verify_code.strip().upper(),))
                verify_result = cur.fetchone()

    return templates.TemplateResponse(request, "public.html", {
        "personas": personas,
        "actor": actor,
        "categories": categories,
        "licences": licences,
        "q": q,
        "selected_category": category,
        "verify_code": verify_code,
        "verify_result": verify_result,
        "verify_searched": verify_searched,
        "msg": msg,
        "kind": kind,
        "active_tab": "public",
    })