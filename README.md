# CMA-ORLP: Online Regulatory and Licensing Portal

A demo of the Capital Markets Authority (Kenya) licensing and compliance portal, built on PostgreSQL.

This is a presentation demo, not the full system. It covers the internal officer screens:

- **P22** Checklist Review and Fit and Proper Assessment (Licence Officer)
- **P27** Filing Calendar and Exception Alert Dashboard (Compliance Officer)
- Landing page, help page, and supporting applicant, staff and audit pages

## Stack
PostgreSQL 16 (schemas iam, cfg, app, doc, wf, fin, lic, cmp, ntf, aud, rpt), FastAPI, Jinja2, psycopg 3. No CDN needed; works offline.

## Run
1. `createdb cma_portal`
2. Load in order:
   ```
   psql -d cma_portal -f cma_portal_database.sql
   psql -d cma_portal -f schema_fixes_and_seed.sql
   psql -d cma_portal -f seed_presentation_demo.sql
   ```
3. `pip install -r requirements.txt`
4. Create `.env`:
   ```
   DATABASE_URL="dbname=cma_portal"
   DEMO_MODE=true
   ```
5. `uvicorn app.main:app --reload`, then open http://localhost:8000

## Demo walkthrough
1. Open `/` (landing).
2. Switch persona in the sidebar to David Otieno, then open `/staff/case/CASE/2026/000101/review`. Record checklist results and a Fit and Proper outcome. A "not met" result without remarks is refused by the database.
3. Switch to Beatrice Njoroge and open `/compliance`. Update an exception status and export the CSV.

Persona switching is demo-only and is not authentication. Set `DEMO_MODE=false` to disable `/reset-demo`.

## Tests
`psql -d cma_portal -f cma_portal_tests.sql` on a fresh database (18 checks). `sanity_check.sql` gives a quick data check.

## Known database issues
Password hash readable by service roles, INSERTs bypass some status triggers, PAID without a settled payment, licence from a non-approved decision, editable published category version, 54 unindexed foreign keys, audit-seal race.
