# Demo script: 3 minutes (Mon 16 Nov, 08:00)

**Before you go in:** reload a fresh database (README steps 1-2), start the app, open three tabs: `/`, `/staff/case/CASE/2026/000101/review`, `/compliance`. Fallback screenshots are in `docs/demo/`. If the live app fails, show them and keep talking.

## 0:00 Landing (15 s)
"This is the CMA Online Regulatory and Licensing Portal. We built the internal officer side on PostgreSQL. Two screens: one input, one output."

## 0:15 Input: P22 Checklist Review and Fit and Proper (90 s)
1. Persona: **David Otieno** (Licensing Officer). Point out the case header: Alpha Securities Ltd, Fund Manager, SLA due date, "8 items remaining".
2. Checklist CHK-01: choose **NOT MET**, leave remarks empty, Save. The database refuses it: the rule is a check constraint, not just a form rule. Then add remarks, or choose MET, and Save.
3. Fit and Proper: show Grace Muthoni's disclosed 2021 sanction. Record an outcome with a rationale.
4. Mention "Raise query" pauses the SLA clock, and "Submit review" unlocks only when all 8 items are done.

## 1:45 Output: P27 Filing Calendar and Exception Alerts (60 s)
1. Persona: **Beatrice Njoroge** (Supervision). Show the overdue returns for Savannah Capital Partners, with days overdue.
2. Change one exception to UNDER REVIEW. The status chip carries a word, not just a colour.
3. Click **Export CSV**.

## 2:45 Close (15 s)
"Every change is attributed to the acting officer in the audit log. Persona switching is demo-only, not authentication."

## Likely questions
- **Why PostgreSQL rules, not only app code?** Rules hold for every client, and the audit trail depends on them.
- **Is login real?** No. Persona switcher is demo scope. Real authentication is future work.
- **Known gaps?** Listed in README (password hash visibility, trigger bypass on INSERT, indexes). Planned after the presentation.

## Seven design considerations (for the class vote)
Page frame, colour, typography, controls, accessibility, feedback and errors, security. Detail is in the Task 11 document.
