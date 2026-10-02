# E-Commerce Analytics Pipeline

End-to-end analytics engineering portfolio project: **messy raw data → PostgreSQL → dbt (staging → star schema → KPI/cohort/funnel marts, fully tested) → Power BI-ready marts**, orchestrated by Apache Airflow.

The data is *deliberately* messy (missing fields, duplicates, mixed date formats, inconsistent event-type spellings, malformed lines) so that every cleaning rule in the pipeline is justified by a real, visible data defect — and so every design decision is defensible in an interview.

---

## Architecture

```
data_generator/generate_data.py        deliberately messy JSONL + CSV files
        │                                (deterministic: fixed seed)
        ▼  Airflow task 1 ── generate_data
data_generator/load_raw.py             files → schema `raw` (JSONB payloads,
        │                                untouchable landing zone; malformed
        │                                lines → dead-letter file)
        ▼  Airflow task 2 ── load_raw
dbt/ecommerce_dbt                      dbt build (models + tests)
  staging/    1:1 with raw, cleaned & typed, deduplicated
  marts/      dim_customers, dim_products            (dimensions, SCD1)
              fct_orders, fct_events               (transactional facts)
              fct_funnel                           (accumulating snapshot)
              mart_kpi_daily, mart_cohort_retention, mart_funnel_conversion
  tests/      generic (unique, not_null, relationships, accepted_values,
              expression_is_true) + singular SQL tests
        ▼  Airflow task 3 ── dbt_build   (fails loudly on any test failure)
Airflow task 4 ── health_check         marts exist and are populated
        ▼
Power BI (not in repo)                 star-schema semantic model on marts.*
```

## Repository layout

```
ecommerce-analytics-pipeline/
├── docker-compose.yml              PostgreSQL 16 + Airflow (LocalExecutor)
├── .env.example                    copy to .env, adjust if you like
├── data_generator/
│   ├── generate_data.py            messy data producer (seeded → reproducible)
│   ├── load_raw.py                 loader with dead-letter handling
│   └── requirements.txt
├── airflow/
│   ├── Dockerfile                  airflow image + dbt-postgres
│   └── dags/ecommerce_pipeline_dag.py
├── dbt/ecommerce_dbt/
│   ├── dbt_project.yml             layers, materializations, test config
│   ├── profiles.yml                dev target (env-var driven)
│   ├── packages.yml                dbt_utils
│   ├── models/
│   │   ├── staging/                sources.yml + 4 stg_ models + tests
│   │   └── marts/                  3 dims/facts + 3 marts + tests
│   └── tests/                      singular (custom SQL) tests
├── docs/SETUP_WINDOWS.md           step-by-step Windows guide
└── data/raw/                       generated files (git-ignored)
```

## Quick start (Docker, recommended)

Prereqs: Docker Desktop (with WSL2 backend) and `docker compose`.

```powershell
cd D:\Projects\ecommerce-analytics-pipeline
copy .env.example .env
docker compose up -d --build
```

Then:

1. **Airflow UI** → http://localhost:8080 (user/password from `.env`, defaults `admin`/`admin`)
2. Unpause the DAG `ecommerce_analytics_pipeline` and trigger a run — or wait for the daily schedule.
3. **Warehouse** → connect with DBeaver/psql to `localhost:5432`, database `shop`, user `analytics`.
4. Inspect results: `select * from marts.mart_kpi_daily order by order_date desc;`

## Quick start (no Docker — local Python)

You only need PostgreSQL running locally (or in Docker alone: `docker compose up -d postgres`).

```powershell
cd D:\Projects\ecommerce-analytics-pipeline
python -m venv .venv; .\.venv\Scripts\Activate.ps1
pip install -r data_generator/requirements.txt dbt-postgres==1.8.2

# 1) generate + load
python data_generator/generate_data.py
python data_generator/load_raw.py

# 2) transform + test
cd dbt/ecommerce_dbt
dbt deps
dbt build
```

## Key design decisions (interview defense)

| Decision | Why |
|---|---|
| Raw layer is JSONB and untouchable | Reproducibility + debuggability; cleaning rules live in versioned SQL, not in a one-off script |
| Staging cleans, marts decide | Layering contract: staging never drops business-meaningful rows (flags them); the fact table applies business filters |
| Star schema, SCD Type 1 | Fewer joins, BI-friendly; Type 2 only if historical attribute questions matter (→ dbt snapshots) |
| `fct_funnel` as accumulating snapshot | One row per session, one timestamp column per milestone → conversions are counts, timings are same-row DATEDIFFs |
| `dbt build` in the DAG | Tests are part of the pipeline; a broken join fails the run before Power BI can show a wrong number |
| Malformed lines → dead-letter file | Bad data is surfaced and counted, never silently dropped |
| Deterministic generator (seed 42) | Every run of the pipeline is reproducible — demo-safe |

## Power BI connection (after a successful run)

Get data → PostgreSQL → `localhost:5432` / `shop` / `analytics`. Load the `marts` schema tables; relate facts to dims on the `*_sk` columns. Revenue is already a column on `fct_orders` — define one DAX measure for presentation, don't re-implement business logic.

## Docs

- [docs/SETUP_WINDOWS.md](docs/SETUP_WINDOWS.md) — detailed Windows walkthrough, troubleshooting, and how to demo the pipeline live.
