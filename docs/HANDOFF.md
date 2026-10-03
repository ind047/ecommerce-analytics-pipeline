# SESSION HANDOFF — continue here on the Mac

**Date:** 2026-10-03 · **Goal:** analytics engineering interview (Oct 8) — portfolio pipeline project
**Mode:** teacher/coach — user learns and defends every piece; answer-key code exists in repo as reference

---

## 1. The project (one paragraph)

End-to-end analytics pipeline: deliberately messy e-commerce data (Python generator) → PostgreSQL `raw` landing zone (JSONB, dead-lettering) → dbt (staging → star schema: dim_customers, dim_products, fct_orders, fct_events, accumulating-snapshot fct_funnel → marts: mart_kpi_daily, mart_cohort_retention, mart_funnel_conversion; all tested) → Airflow DAG (generate → load → dbt build → health check) → Power BI on marts. Interview pitch line: *"one trusted, tested definition of every metric, served to any tool that consumes it."*

## 2. What's done (verified)

- ✅ **Step 0 — env (Windows):** uv installed (winget), venv at `.venv` pinned to Python 3.11 (`C:\Program Files\Python311`), Faker installed. On Mac: `brew install uv`, recreate venv.
- ✅ **Step 1 — data generator:** 4 files in `data/raw/` verified: customers.csv 1,220 lines / products.csv 305 / orders.csv 20,195 / events.jsonl 80,000. Deterministic (seed). NOTE: user ran answer-key code (copied); earned retroactively via explain-backs (done for Step 2 loader; still owed: one self-made modification to generate_data.py — options were (a) uppercase-email defect, (b) 5th event type, (c) time-of-day skew).
- ✅ **Git:** repo initialized, 1 commit (`Project scaffold: ...`) + checkpoint commit (see §5). Remote: `https://github.com/ind047/ecommerce-analytics-pipeline.git` — **push NOT yet successful (auth) — see §4.**
- ✅ **Step 2 theory (loader):** all 4 explain-back questions answered and corrected — (1) JSONB payload + loaded_at = schema-on-read, typing pushed to tested dbt code; (2) truncate safe because source delivers full snapshots; append-only archive needed for delta sources/replay/audit; (3) dead-letter file = quarantine + measurable failure rate + accountability, never silent loss; (4) Python parsing over COPY tolerates ragged rows/nested JSON per-row, cost = speed, escalation = COPY to text staging then JSONB.

## 3. Where we resume — Step 2 hands-on

Next actions, in order (on Mac unless noted):

1. Get project onto Mac: **must fix git auth and push from Windows first** (§4), then `git clone` on Mac. Fallback: copy the whole folder via AirDrop/Drive.
2. Install Docker Desktop (Mac) + `brew install uv`; `uv venv .venv --python 3.11` (or `uv python install 3.11`); `uv pip install -r data_generator/requirements.txt`.
3. `docker compose up -d postgres` → wait for `healthy` (`docker compose ps`).
4. `python data_generator/generate_data.py` then `python data_generator/load_raw.py` → expect four `[OK]` lines + dead-letter note.
5. Verify in DB: `docker exec -it shop_postgres psql -U analytics -d shop -c "select count(*) from raw.customers;"` (+ 2 queries from session: sample payload, `payload ->> 'email'`).
6. Commit: `"Step 2: raw landing zone loads messy CSV/JSONL into Postgres as JSONB"`.
7. Then **Step 3 (dbt staging)** — the main event: user WRITES the staging SQL (answer key in repo for reference after attempting). Install dbt: `uv pip install dbt-postgres==1.8.2`. Key lesson already seeded: dbt's default schema naming gives `dbt_staging` not `staging` — repo has `macros/generate_schema_name.sql` override; make user explain it before using.

## 4. Blockers / open items

- **Git auth (Windows):** `git push -u origin main` fails — "Password authentication is not supported." Fix via `gh auth login` (`winget install GitHub.cli`, browser flow) OR classic PAT with `repo` scope used as password. Nothing reaches the Mac until this works (or manual copy).
- **Windows Docker (parked, not failed):** WSL2/docker-desktop distro broke after overnight Windows update; auto-updated to Docker 29.8.1, then "Docker Desktop is unable to start". Debug ladder already applied: reboot → re-import → factory reset → (auto-update happened). One `docker run hello-world` on Windows before Power BI day (Step 6) — engine may just work now. Interview story material: layered OS→WSL→engine diagnosis.
- **Host naming lesson:** scripts on host use `localhost`; containers use service name `postgres` (compose sets `POSTGRES_HOST` accordingly). User asked this spontaneously — good sign.

## 5. Teaching log — concepts already covered (don't re-teach, do drill)

- Why venv; `faker` module vs `Faker` class; `pip install` vs `uv pip install` (user was asked — answers not yet verified/recorded; re-ask briefly).
- uv Python management (`uv python list`, `uv venv --python`), venv disposal (delete folder; never rename).
- Reproducibility: fixed seed → debugging, meaningful tests, CI; nuance: generator anchors at `datetime.now()` so dates drift, shape fixed.
- Mess defect catalog: test orders, negative quantities, duplicated events, 3 date formats, event-type mislabeling, missing fields, malformed JSONL lines — each maps to a cleaning rule + test + interview answer.
- Semicolon CSV = European decimal-comma locale quirk; traps naive comma parsers.
- Regex date-format detection beats blind parsing (ambiguity of `01/03/2025`; unmatched → NULL → not_null test).
- Injected RNG (not module-global random) = local determinism, explicit dependencies.
- Git: never commit `.venv/`, `data/raw/`, `.env`, dbt `target/`; `.gitattributes`/LF-CRLF warnings are harmless; read `git status` before every commit.

## 6. Rules of engagement (user's preferences)

- User wants to LEARN, not watch: explain first, let them run everything themselves, review their outputs.
- Time is tight (interview Oct 8): pragmatic mix — theory explained thoroughly (teacher mode), hands-on strictest for dbt SQL (Steps 3–4, ~60% of interview value), glue steps guided.
- User communicates in short bursts; keep next actions as numbered command blocks.
- Roadmap: Step 2 loader (in progress) → 3 dbt staging (~2h) → 4 dbt marts (~2.5h) → 5 Airflow DAG (~1h) → 6 Power BI (~1h, back on Windows) → 7 polish + dbt docs lineage (~30m). Weekend: 2–4 Sat, 5–6 Sun; drills Mon–Wed vs prep docs (in workspace root: `Analytics_Pipeline_Interview_Prep.md`, `DEVDEER_RAG_Interview_Prep.md`).
- Interview framing: user is a career-switcher with two DEVDEER projects (SQL-RAG, LangChain chatbot) — cross-project questions exist in prep docs.
