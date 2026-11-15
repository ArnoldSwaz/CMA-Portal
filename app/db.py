import getpass
import os
from contextlib import contextmanager
from urllib.parse import quote_plus

import psycopg
from dotenv import load_dotenv
from fastapi import Request
from fastapi.responses import RedirectResponse
from psycopg.rows import dict_row

load_dotenv()

DEFAULT_USER = getpass.getuser()
DATABASE_URL = os.getenv("DATABASE_URL", f"dbname=cma_portal user={DEFAULT_USER}")
DEMO_MODE = os.getenv("DEMO_MODE", "true").lower() in ("1", "true", "yes")
DEFAULT_ACTOR = "10000000-0000-0000-0000-000000000001"  # Amina Wanjiru (Applicant)


@contextmanager
def get_db(actor_id: str | None = None):
    conn = psycopg.connect(DATABASE_URL, row_factory=dict_row)
    try:
        with conn.transaction():
            if actor_id:
                with conn.cursor() as cur:
                    cur.execute("SELECT set_config('app.account_id', %s, true);", (str(actor_id),))
            yield conn
    finally:
        conn.close()


def flash_redirect(url: str, msg: str, kind: str = "success") -> RedirectResponse:
    sep = "&" if "?" in url else "?"
    return RedirectResponse(url=f"{url}{sep}msg={quote_plus(msg)}&kind={kind}", status_code=303)


def get_personas(conn) -> list[dict]:
    with conn.cursor() as cur:
        cur.execute("""
            SELECT a.account_id::text AS account_id,
                   a.account_type,
                   a.entity_id::text AS entity_id,
                   p.person_id::text AS person_id,
                   p.full_name,
                   e.registered_name AS entity_name,
                   coalesce(array_agg(r.role_code ORDER BY r.role_code)
                            FILTER (WHERE r.role_code IS NOT NULL), '{}') AS roles
              FROM iam.account a
              JOIN iam.person p ON p.person_id = a.person_id
              LEFT JOIN iam.entity e ON e.entity_id = a.entity_id
              LEFT JOIN iam.account_role ar ON ar.account_id = a.account_id
              LEFT JOIN iam.role r ON r.role_id = ar.role_id
             WHERE a.status = 'ACTIVE'
             GROUP BY a.account_id, a.account_type, a.entity_id, p.person_id, p.full_name, e.registered_name
             ORDER BY (e.registered_name IS NULL), p.full_name;
        """)
        return cur.fetchall()


def resolve_actor(request: Request, personas: list[dict]) -> dict:
    cookie_id = request.cookies.get("actor_id") or DEFAULT_ACTOR
    for p in personas:
        if p["account_id"] == cookie_id:
            return p
    return personas[0]