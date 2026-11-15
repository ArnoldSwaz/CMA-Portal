import calendar
import csv
import io
from datetime import date, datetime
from pathlib import Path
from typing import Optional

import psycopg
from fastapi import APIRouter, Form, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.templating import Jinja2Templates

from app.db import flash_redirect, get_db, get_personas, resolve_actor

BASE_DIR = Path(__file__).resolve().parent.parent
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))
templates.env.cache = None

router = APIRouter(prefix="/compliance")


def _parse_month(month_str: Optional[str]) -> tuple[int, int, str]:
    today = date.today()
    if month_str:
        try:
            dt = datetime.strptime(month_str.strip(), "%Y-%m")
            return dt.year, dt.month, dt.strftime("%Y-%m")
        except ValueError:
            pass
    return today.year, today.month, today.strftime("%Y-%m")


def _shift_month(year: int, month: int, delta: int) -> str:
    m = month + delta
    y = year
    while m > 12:
        m -= 12
        y += 1
    while m < 1:
        m += 12
        y -= 1
    return f"{y:04d}-{m:02d}"


@router.get("", response_class=HTMLResponse)
async def compliance_dashboard(
    request: Request,
    month: Optional[str] = None,
    category: str = "",
    return_code: str = "",
):
    year, mon, month_label = _parse_month(month)
    prev_month = _shift_month(year, mon, -1)
    next_month = _shift_month(year, mon, 1)
    month_title = date(year, mon, 1).strftime("%B %Y")

    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

        with conn.cursor() as cur:
            # Dropdown filter options
            cur.execute("""
                SELECT category_code, category_name
                  FROM cfg.licence_category
                 ORDER BY category_name;
            """)
            categories = cur.fetchall()

            cur.execute("""
                SELECT return_code, return_name
                  FROM cfg.return_type
                 ORDER BY return_code;
            """)
            return_types = cur.fetchall()

            # All filing obligations from cmp.v_filing_calendar
            cur.execute("""
                SELECT v.obligation_id::text,
                       v.licence_number,
                       v.return_code,
                       v.return_name,
                       v.period_start,
                       v.period_end,
                       v.due_date,
                       v.status,
                       v.days_to_due,
                       e.registered_name AS entity_name,
                       lc.category_code,
                       lc.category_name
                  FROM cmp.v_filing_calendar v
                  LEFT JOIN iam.entity e ON e.entity_id = v.holder_entity_id
                  LEFT JOIN lic.licence l ON l.licence_number = v.licence_number
                  LEFT JOIN cfg.licence_category lc ON lc.category_id = l.category_id
                 WHERE (%s = '' OR lc.category_code = %s)
                   AND (%s = '' OR v.return_code = %s)
                 ORDER BY v.due_date ASC, v.return_code ASC;
            """, (category, category, return_code, return_code))
            obligations = cur.fetchall()

            # Compliance exceptions sorted by days late descending (Task 11 P27)
            cur.execute("""
                SELECT ce.exception_id::text,
                       ce.exception_type,
                       ce.details,
                       ce.status,
                       ce.raised_at,
                       l.licence_number,
                       e.registered_name AS entity_name,
                       lc.category_code,
                       lc.category_name,
                       rt.return_code,
                       rt.return_name,
                       fo.due_date,
                       greatest(0, (current_date - coalesce(fo.due_date, ce.raised_at::date)))::int AS days_late,
                       cf.case_id::text AS case_id,
                       cf.case_number
                  FROM cmp.compliance_exception ce
                  JOIN lic.licence l ON l.licence_id = ce.licence_id
                  JOIN iam.entity e ON e.entity_id = l.holder_entity_id
                  JOIN cfg.licence_category lc ON lc.category_id = l.category_id
                  LEFT JOIN cmp.filing_obligation fo ON fo.obligation_id = ce.obligation_id
                  LEFT JOIN cfg.return_type rt ON rt.return_type_id = fo.return_type_id
                  LEFT JOIN wf.case_file cf ON cf.compliance_exception_id = ce.exception_id
                 WHERE (%s = '' OR lc.category_code = %s)
                   AND (%s = '' OR rt.return_code = %s)
                 ORDER BY days_late DESC, ce.raised_at ASC;
            """, (category, category, return_code, return_code))
            exceptions = cur.fetchall()

    # Build monthly calendar grid (Monday = 0 .. Sunday = 6)
    cal = calendar.Calendar(firstweekday=0)
    weeks_raw = cal.monthdatescalendar(year, mon)
    by_day: dict[date, list[dict]] = {}
    for ob in obligations:
        by_day.setdefault(ob["due_date"], []).append(ob)

    today = date.today()
    calendar_weeks = []
    for week in weeks_raw:
        row = []
        for d in week:
            row.append({
                "date": d,
                "in_month": d.month == mon,
                "is_today": d == today,
                "obligations": by_day.get(d, []),
            })
        calendar_weeks.append(row)

    # KPI Summary Metrics
    overdue_count = sum(1 for ob in obligations if ob["status"] == "OVERDUE")
    due_soon_count = sum(
        1 for ob in obligations
        if ob["status"] == "UPCOMING" and ob["days_to_due"] is not None and 0 <= ob["days_to_due"] <= 7
    )
    open_exceptions = sum(1 for ex in exceptions if ex["status"] in ("OPEN", "UNDER_REVIEW"))
    critical_late = sum(1 for ex in exceptions if ex["status"] != "RESOLVED" and ex["days_late"] >= 7)

    return templates.TemplateResponse(request, "compliance.html", {
        "personas": personas,
        "actor": actor,
        "categories": categories,
        "return_types": return_types,
        "selected_category": category,
        "selected_return_code": return_code,
        "month_label": month_label,
        "month_title": month_title,
        "prev_month": prev_month,
        "next_month": next_month,
        "calendar_weeks": calendar_weeks,
        "obligations": obligations,
        "exceptions": exceptions,
        "overdue_count": overdue_count,
        "due_soon_count": due_soon_count,
        "open_exceptions": open_exceptions,
        "critical_late": critical_late,
        "active_nav": "compliance",
    })


@router.post("/exception/{exception_id}/status")
async def update_exception_status(
    request: Request,
    exception_id: str,
    status: str = Form(...),
):
    with get_db() as conn:
        personas = get_personas(conn)
        actor = resolve_actor(request, personas)

    try:
        with get_db(actor["account_id"]) as conn:
            with conn.cursor() as cur:
                cur.execute("""
                    UPDATE cmp.compliance_exception
                       SET status = %s,
                           resolved_at = CASE
                               WHEN %s IN ('RESOLVED', 'REFERRED_TO_ENFORCEMENT') THEN now()
                               ELSE NULL
                           END
                     WHERE exception_id = %s;
                """, (status, status, exception_id))
        return flash_redirect("/compliance", f"Exception status updated to {status}.")
    except psycopg.Error as e:
        return flash_redirect(
            "/compliance",
            f"Database Rule Enforced: {e.diag.message_primary or str(e)}",
            "error",
        )


@router.get("/export.csv")
async def export_compliance_csv(
    category: str = "",
    return_code: str = "",
):
    with get_db() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                SELECT v.licence_number,
                       e.registered_name AS entity_name,
                       lc.category_name,
                       v.return_code,
                       v.return_name,
                       v.period_start,
                       v.period_end,
                       v.due_date,
                       v.status,
                       v.days_to_due
                  FROM cmp.v_filing_calendar v
                  LEFT JOIN iam.entity e ON e.entity_id = v.holder_entity_id
                  LEFT JOIN lic.licence l ON l.licence_number = v.licence_number
                  LEFT JOIN cfg.licence_category lc ON lc.category_id = l.category_id
                 WHERE (%s = '' OR lc.category_code = %s)
                   AND (%s = '' OR v.return_code = %s)
                 ORDER BY v.due_date ASC;
            """, (category, category, return_code, return_code))
            rows = cur.fetchall()

    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow([
        "Licence Number", "Regulated Entity", "Category",
        "Return Code", "Return Name", "Period Start",
        "Period End", "Due Date", "Status", "Days To Due",
    ])
    for r in rows:
        writer.writerow([
            r["licence_number"],
            r["entity_name"] or "",
            r["category_name"] or "",
            r["return_code"],
            r["return_name"],
            r["period_start"],
            r["period_end"],
            r["due_date"],
            r["status"],
            r["days_to_due"],
        ])

    buf.seek(0)
    return StreamingResponse(
        iter([buf.getvalue()]),
        media_type="text/csv",
        headers={"Content-Disposition": "attachment; filename=cma_filing_compliance_report.csv"},
    )