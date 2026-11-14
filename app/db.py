import os
from contextlib import contextmanager
from urllib.parse import quote

import psycopg
from fastapi import Request
from fastapi.responses import RedirectResponse
from psycopg.rows import dict_row

DB_DSN = os.getenv("DATABASE_URL", "dbname=cma_portal user=swaz")
SYSTEM_ACCOUNT_ID = "00000000-0000-0000-0000-000000000001"


@contextmanager
def get_db(actor_account_id: str | None = None):
    """Opens a PostgreSQL transaction with app.account_id set for audit logging."""
    actor = actor_account_id or SYSTEM_ACCOUNT_ID
    with psycopg.connect(DB_DSN, row_factory=dict_row) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT set_config('app.account_id', %s, true);", (str(actor),))
        yield conn
        conn.commit()


def flash_redirect(url: str, msg: str, kind: str = "success") -> RedirectResponse:
    """Redirects back to a page with a status banner message."""
    sep = "&" if "?" in url else "?"
    return RedirectResponse(url=f"{url}{sep}msg={quote(msg)}&kind={kind}", status_code=303)


def get_personas(conn) -> list[dict]:
    """Fetches all active demo users and their assigned roles."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT a.account_id::text, a.account_type, p.full_name, p.email_address,
                   e.registered_name AS entity_name, a.entity_id::text,
                   coalesce(array_agg(r.role_code) FILTER (WHERE r.role_code IS NOT NULL), '{}') AS roles
              FROM iam.account a
              JOIN iam.person p ON p.person_id = a.person_id
              LEFT JOIN iam.entity e ON e.entity_id = a.entity_id
              LEFT JOIN iam.account_role ar ON ar.account_id = a.account_id AND ar.revoked_at IS NULL
              LEFT JOIN iam.role r ON r.role_id = ar.role_id
             WHERE a.account_type <> 'SYSTEM' AND a.status = 'ACTIVE'
             GROUP BY a.account_id, a.account_type, p.full_name, p.email_address, e.registered_name, a.entity_id
             ORDER BY a.account_type, p.full_name;
        """)
        return cur.fetchall()


def resolve_actor(request: Request, personas: list[dict]) -> dict:
    """Returns whichever user is currently selected in the top-right persona switcher."""
    cookie_id = request.cookies.get("actor_id")
    for p in personas:
        if p["account_id"] == cookie_id:
            return p
    return personas[0]