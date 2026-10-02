# ---------------------------------------------------------------------------
# Custom Airflow image: official Airflow + dbt-postgres + postgres provider.
# One image keeps the demo single-node-simple while still letting the DAG run
# `dbt build` as a BashOperator task inside the Airflow container.
# ---------------------------------------------------------------------------
FROM apache/airflow:2.9.3-python3.11

USER airflow

# dbt-postgres: the transformation tool, targeted at our Postgres warehouse.
# apache-airflow-providers-postgres: PostgresHook/PostgresOperator support.
# Versions aligned with Airflow 2.9 + dbt Core 1.8.
RUN pip install --no-cache-dir \
    dbt-postgres==1.8.2 \
    apache-airflow-providers-postgres==5.11.1
