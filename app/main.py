import subprocess
from pathlib import Path

from fastapi import FastAPI, Request
from fastapi.staticfiles import StaticFiles

from app.db import DEMO_MODE, flash_redirect
from app.routers import applicant, audit, compliance, public, staff

app = FastAPI(title="CMA Online Regulatory & Licensing Portal (CMA-ORLP)")

BASE_DIR = Path(__file__).resolve().parent
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")

app.include_router(public.router)
app.include_router(applicant.router)
app.include_router(staff.router)
app.include_router(compliance.router)
app.include_router(audit.router)


@app.post("/reset-demo")
def reset_demo(request: Request):
    if not DEMO_MODE:
        return flash_redirect("/", "Demo reset is disabled in production mode.", "error")

    root = BASE_DIR.parent
    subprocess.run(
        [
            "psql", "-d", "cma_portal", "-v", "ON_ERROR_STOP=1", "-c",
            "DROP SCHEMA IF EXISTS aud, rpt, cmp, lic, fin, wf, doc, app, cfg, iam, ntf CASCADE;",
        ],
        check=True,
    )
    subprocess.run(["psql", "-d", "cma_portal", "-v", "ON_ERROR_STOP=1", "-f", str(root / "cma_portal_database.sql")], check=True)
    subprocess.run(["psql", "-d", "cma_portal", "-v", "ON_ERROR_STOP=1", "-f", str(root / "schema_fixes_and_seed.sql")], check=True)

    demo_patch = root / "seed_presentation_demo.sql"
    if demo_patch.exists():
        subprocess.run(["psql", "-d", "cma_portal", "-v", "ON_ERROR_STOP=1", "-f", str(demo_patch)], check=True)

    return flash_redirect("/hub", "Database reset to clean demo baseline.", "success")