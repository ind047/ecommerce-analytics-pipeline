# Windows Setup Guide — E-Commerce Analytics Pipeline

Step-by-step walkthrough for Windows 10/11. Two paths: **full Docker stack** (recommended, matches the interview story) and **hybrid** (Postgres in Docker, Python + dbt on the host). Everything below assumes the project lives at `D:\Projects\ecommerce-analytics-pipeline`.

---

## Path A — Full Docker stack (recommended)

### A1. Prerequisites

1. **Docker Desktop for Windows** — install from docker.com, enable the **WSL 2 backend** (default on recent versions).
2. Verify in PowerShell:
   ```powershell
   docker --version        # e.g. Docker version 27.x
   docker compose version  # e.g. v2.x
   ```

### A2. Start the stack

```powershell
cd D:\Projects\ecommerce-analytics-pipeline
copy .env.example .env
docker compose up -d --build
```

The first build takes 5–15 minutes (the Airflow image installs dbt-postgres).

### A3. Verify services are healthy

```powershell
docker compose ps          # postgres: healthy, airflow: up
```

- Airflow UI: http://localhost:8080 — log in with `admin` / `admin` (from `.env`).
- Postgres: `localhost:5432`, db `shop`, user `analytics`, password `analytics`.

### A4. Run the pipeline

1. In the Airflow UI, find DAG `ecommerce_analytics_pipeline`.
2. Toggle it **On** (unpause), then press ▶ **Trigger DAG**.
3. Watch the Graph view: `generate_data → load_raw → dbt_build → health_check`. All four boxes turn dark green = success. `dbt_build` runs 13 models + 20+ tests; a red box means a test failed — click the task → Log to see which one and why (this is the demo!).

### A5. Inspect the results

PowerShell (no extra tools needed — use the postgres container's psql):

```powershell
docker exec -it shop_postgres psql -U analytics -d shop -c "select * from marts.mart_kpi_daily order by order_date desc limit 10;"
docker exec -it shop_postgres psql -U analytics -d shop -c "select * from marts.mart_funnel_conversion;"
```

Or connect DBeaver / Power BI to `localhost:5432`.

---

## Path B — Hybrid (Postgres in Docker, Python + dbt on Windows host)

Use this if Docker Desktop is slow or unavailable, or you want to step through the code in an IDE.

### B1. Start only Postgres

```powershell
cd D:\Projects\ecommerce-analytics-pipeline
docker compose up -d postgres
```

### B2. Python environment

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r data_generator/requirements.txt
pip install dbt-postgres==1.8.2
```

> If `python` isn't found: install Python 3.11+ from python.org and check **"Add python.exe to PATH"**.

### B3. Generate and load raw data

```powershell
python data_generator/generate_data.py   # writes ~100k rows into data\raw
python data_generator/load_raw.py        # creates schema raw, truncates, loads
```

Expected output: four `[OK]` lines with row counts, plus a note about a handful of malformed event lines routed to `data\raw\_dead_letters\` — that is intentional, talk about it.

### B4. Run dbt

```powershell
cd dbt\ecommerce_dbt
dbt deps      # downloads dbt_utils into dbt_packages
dbt build     # builds all models, then runs all tests
```

Success looks like: `Completed successfully ... Done. PASS=...` with no ERROR lines. Then explore:

```powershell
dbt docs generate
dbt docs serve    # lineage graph at http://localhost:8080
```

The lineage graph is a great interview artifact — raw sources → staging → star schema → marts, clickable, generated from the same YAML you tested.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `port is already allocated` for 5432/8080 | Another Postgres/Airflow is running. Stop it, or edit `docker-compose.yml` ports (e.g. `"5433:5432"`) and update `.env` + `profiles.yml` host port. |
| Airflow container keeps restarting | Check logs: `docker compose logs airflow`. Usually the first-ever `dbt deps` needs network access, or the DB wasn't healthy yet — it retries; give it a minute. |
| `dbt build` fails with "connection refused" | Inside Docker, host must be `postgres` (service name) — already set via `POSTGRES_HOST` in compose. On the host, use `localhost` (already the default in `profiles.yml`). |
| `dbt deps` fails behind a proxy | Set `HTTPS_PROXY`/`HTTP_PROXY` env vars before running, or run `dbt deps` once on the host and copy `dbt_packages/` into the container-mounted folder. |
| Power BI can't see `marts` schema | You connected before dbt ran. The schema is created on first `dbt build`. Re-run and refresh the navigator. |
| `execution policy` error activating venv | Run PowerShell as needed: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |

---

## Weekend build plan (Oct 3–4) + drilling hooks (Oct 5–7)

**Sat AM** — Path A up; run pipeline once end-to-end; open `dbt docs` lineage graph. **Sat PM** — read every file in `models/staging/` alongside the generator; be able to name which generator defect each cleaning rule fixes. **Sun AM** — marts: walk `fct_funnel` (accumulating snapshot pitch) and `mart_cohort_retention` (window-function pitch). **Sun PM** — break things on purpose: delete a dedup CTE and watch the `unique` test fail; rerun. **Mon–Wed** — drill the Q&A docs; for every SQL answer, point at the model in this repo that demonstrates it.

## Demo-day script (2 minutes, live)

1. Show the DAG in Airflow → trigger a run.
2. While it runs: generator → loader → dbt build on the whiteboard.
3. When green: open `marts.mart_funnel_conversion` in psql — "conversion is a COUNT of non-NULL milestone columns; that's the accumulating snapshot."
4. Finish with `dbt docs` lineage graph: "every number in Power BI traces back to a tested model — that's the contract."
