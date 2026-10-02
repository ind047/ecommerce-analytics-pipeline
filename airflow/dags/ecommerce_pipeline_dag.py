# -*- coding: utf-8 -*-
"""
=============================================================================
 ecommerce_pipeline_dag.py — orchestrate generate -> load -> dbt build
=============================================================================
 THE ORCHESTRATION STORY (interview answer):
   "Airflow schedules and monitors the pipeline as a DAG — a directed
    acyclic graph of tasks with explicit dependencies. Each run follows
    four steps: generate fresh raw data, load it into the raw schema,
    run dbt build (models + tests), and a final health check. Tasks have
    retries with exponential backoff, and if dbt tests fail the DAG run
    fails visibly — tests are part of the pipeline, not an afterthought."

 DESIGN CHOICES, EXPLAINED:
   * BashOperator for generate/load/dbt: the pipeline is project scripts
     already; Airflow's job is WHEN and IN WHAT ORDER, not re-implementing
     logic. Idempotency lives in the scripts (truncate-and-load, full
     rebuild marts), so reruns are safe.
   * retries=2 with retry_delay 1min then backoff: transient Docker/DB
     hiccups self-heal; persistent failures surface after bounded effort.
   * catchup=False: we never backfill a demo pipeline — one run = one day.
=============================================================================
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

# ----------------------------------------------------------------------------
# Container paths (this DAG runs INSIDE the airflow container — see volumes
# in docker-compose.yml which mount these host folders at /opt/...)
# ----------------------------------------------------------------------------
GENERATOR_DIR = "/opt/data_generator"
DBT_PROJECT_DIR = "/opt/dbt/ecommerce_dbt"
DATA_DIR = "/opt/data"

# ----------------------------------------------------------------------------
# Default arguments applied to every task.
#   owner            — who to blame in the UI
#   depends_on_past  — FALSE: a failed yesterday doesn't block today
#                      (raw is truncate-loaded, so runs are independent)
#   retries/backoff  — transient-failure policy
# ----------------------------------------------------------------------------
default_args = {
    "owner": "analytics-engineer",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=1),
    "retry_exponential_backoff": True,   # 1min -> 2min -> 4min between tries
}

with DAG(
    dag_id="ecommerce_analytics_pipeline",
    description="Messy raw data -> PostgreSQL raw layer -> dbt staging/marts -> tested star schema",
    schedule_interval="@daily",          # one full pipeline run per day
    start_date=datetime(2025, 9, 1),     # arbitrary past anchor; catchup off
    catchup=False,                        # no backfill storm on first enable
    max_active_runs=1,                    # never two pipeline runs at once
    default_args=default_args,
    tags=["portfolio", "dbt", "postgres", "ecommerce"],
) as dag:

    # ------------------------------------------------------------------
    # Task 1: generate fresh, deliberately messy source data.
    # The generator is deterministic (seeded), so a rerun reproduces the
    # same dataset — idempotent by construction.
    # ------------------------------------------------------------------
    generate_data = BashOperator(
        task_id="generate_data",
        bash_command=f"python {GENERATOR_DIR}/generate_data.py",
    )

    # ------------------------------------------------------------------
    # Task 2: load files into the raw landing zone.
    # The loader truncates and re-inserts; malformed lines go to a
    # dead-letter file and are reported, never silently dropped.
    # ------------------------------------------------------------------
    load_raw = BashOperator(
        task_id="load_raw",
        bash_command=f"python {GENERATOR_DIR}/load_raw.py",
    )

    # ------------------------------------------------------------------
    # Task 3: dbt build = run models AND tests in dependency order.
    # This is the heart of the contract: `dbt build` fails if ANY test
    # fails (with store_failures=true, violating rows are saved for
    # inspection). --profiles-dir is set via DBT_PROFILES_DIR env var.
    # ------------------------------------------------------------------
    dbt_build = BashOperator(
        task_id="dbt_build",
        bash_command=(
            f"dbt deps --project-dir {DBT_PROJECT_DIR} && "
            f"dbt build --project-dir {DBT_PROJECT_DIR} --target dev"
        ),
        retries=1,   # dbt failures are data problems, not transient ones —
                     # don't hammer the warehouse retrying a real failure
    )

    # ------------------------------------------------------------------
    # Task 4: lightweight health check — prove the marts exist and are
    # populated AFTER tests pass. Cheap, and it gives the UI a green
    # "pipeline produced data" signal independent of dbt's exit code.
    # ------------------------------------------------------------------
    def _check_marts():
        import psycopg
        conninfo = (
            "host=postgres port=5432 dbname=shop "
            "user=analytics password=analytics"
        )
        expected = {
            "marts.mart_kpi_daily": "order_date",
            "marts.mart_cohort_retention": "cohort_month",
            "marts.mart_funnel_conversion": "stage_name",
        }
        with psycopg.connect(conninfo) as conn:
            for table, key_col in expected.items():
                schema, name = table.split(".")
                row = conn.execute(
                    f"select count(*), count({key_col}) "
                    f"from {schema}.{name}"
                ).fetchone()
                if row[0] == 0 or row[1] == 0:
                    raise RuntimeError(f"{table} is empty — pipeline produced no data")
                print(f"[healthcheck] {table}: {row[0]} rows OK")

    health_check = PythonOperator(
        task_id="health_check",
        python_callable=_check_marts,
    )

    # ------------------------------------------------------------------
    # Dependencies: the linear spine of the DAG.
    # generate -> load -> dbt build -> health check
    # ------------------------------------------------------------------
    generate_data >> load_raw >> dbt_build >> health_check
