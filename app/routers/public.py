from pathlib import Path
from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.db import flash_redirect, get_db, get_personas, resolve_actor

BASE_DIR = Path(__file__).resolve().parent.parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
templates.env.cache = None

router = APIRouter()


def _get_portal_stats(cur) -> dict:
    cur.execute("""
        SELECT
          (SELECT count(*) FROM lic.licence WHERE status = 'ACTIVE') AS active_licences,
          (SELECT count(*) FROM app.application) AS total_apps,
          (SELECT count(*) FROM wf.case_file WHERE status <> 'CLOSED') AS open_cases,
          (SELECT count(*) FROM aud.audit_event) AS audit_count;
    """)
    return cur.fetchone()


@router.get("/", response_class=HTMLResponse)
async def public_landing(request: Request, msg: str = "", kind: str = "success"):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)
        with conn.cursor() as cur:
            stats = _get_portal_stats(cur)

    return templates.TemplateResponse(request, "landing.html", {
        "personas": personas,
        "actor": actor,
        "stats": stats,
        "msg": msg,
        "kind": kind,
        "active_nav": "landing",
    })


@router.get("/hub", response_class=HTMLResponse)
async def command_hub(request: Request, msg: str = "", kind: str = "success"):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)
        with conn.cursor() as cur:
            stats = _get_portal_stats(cur)

    return templates.TemplateResponse(request, "hub.html", {
        "personas": personas,
        "actor": actor,
        "stats": stats,
        "msg": msg,
        "kind": kind,
        "active_nav": "hub",
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
        "active_nav": "register",
        "active_tab": "public",
    })


@router.get("/help", response_class=HTMLResponse)
async def help_page(request: Request):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)
        with conn.cursor() as cur:
            cur.execute("SELECT category_code, category_name, validity_months FROM cfg.licence_category ORDER BY category_name;")
            categories = cur.fetchall()

    return templates.TemplateResponse(request, "help.html", {
        "personas": personas,
        "actor": actor,
        "categories": categories,
        "active_nav": "help",
    })


@router.post("/switch-persona")
async def switch_persona(
    account_id: str = Form(...),
    next_url: str = Form("/"),
):
    target = next_url if next_url.startswith("/") else "/"
    resp = flash_redirect(target, "Active demo persona updated.")
    resp.set_cookie(key="actor_id", value=account_id, httponly=True, samesite="lax")
    return resp