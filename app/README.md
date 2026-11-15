# CMA-ORLP demo app (FastAPI + Jinja2 + PostgreSQL)

## Run
1. `createdb cma_portal`
2. Load in order: `psql -d cma_portal -f cma_portal_database.sql`, `schema_fixes_and_seed.sql`, `seed_presentation_demo.sql`
3. `pip install -r requirements.txt`
4. `.env`: `DATABASE_URL="dbname=cma_portal"` and `DEMO_MODE=true`
5. `uvicorn app.main:app --reload` then open http://localhost:8000

## Demo screens
- P01 `/` landing, P22 `/staff/case/CASE/2026/000101/review` (officer: David Otieno), P27 `/compliance` (compliance officer)
- Switch persona in the sidebar. Persona switching is demo-only, not authentication.
