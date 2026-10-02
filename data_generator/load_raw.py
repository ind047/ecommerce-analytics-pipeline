#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
 load_raw.py — landing-zone loader: files on disk -> PostgreSQL schema `raw`
=============================================================================
 WHY A SEPARATE LOADER (interview narrative):
   The raw layer is UNTOUCHABLE landing zone: nothing cleans, nothing drops,
   nothing casts. Every row lands as a JSONB "payload" exactly as delivered,
   plus a load_audit column (loaded_at). That gives three properties you can
   name in the interview:
     1. Reproducibility — transformations can be re-derived from raw forever.
     2. Debuggability  — when a mart number looks wrong you inspect raw,
                         not a half-cleaned intermediate.
     3. Separation     — loading concerns (files, encodings, delimiters) live
                         here; cleaning concerns live in dbt staging.

 WHAT IT DOES:
   1. Creates schema `raw` (if missing) with one JSONB-per-row table per file.
   2. TRUNCATEs the raw tables (fresh batch each run — raw is a landing zone,
      not history; history lives in the marts/snapshots if you add them).
   3. Parses each file LINE BY LINE:
        - CSV files  : parsed with Python's csv module (handles the
                       semicolon delimiter + quoted fields robustly).
        - JSONL file : each line is inserted as-is into JSONB. Lines that
                       fail json.loads are NOT silently dropped — they are
                       counted and written to a dead-letter file so the
                       failure is visible and auditable.
   4. Reports row counts per table.

 CONNECTION: reads env vars POSTGRES_HOST/PORT/USER/PASSWORD/DB,
 with sane local defaults so it also works without docker.
=============================================================================
"""

from __future__ import annotations

import csv
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

import psycopg  # psycopg 3.x

# ----------------------------------------------------------------------------
# 0. Paths and connection config
# ----------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"
DEAD_LETTER_DIR = RAW_DIR / "_dead_letters"

CONNINFO = (
    f"host={os.getenv('POSTGRES_HOST', 'localhost')} "
    f"port={os.getenv('POSTGRES_PORT', '5432')} "
    f"dbname={os.getenv('POSTGRES_DB', 'shop')} "
    f"user={os.getenv('POSTGRES_USER', 'analytics')} "
    f"password={os.getenv('POSTGRES_PASSWORD', 'analytics')}"
)

# name of raw table -> source file + parser type
# (the parse mode documents which loader concern each file triggers)
SOURCES = {
    "customers": ("customers.csv", "csv"),
    "products":  ("products.csv", "csv"),
    "orders":    ("orders.csv", "csv"),
    "events":    ("events.jsonl", "jsonl"),
}

BATCH_SIZE = 5_000   # executemany batch size; keeps memory flat at 80k+ rows

# SQL used for every table: payload + audit column, nothing else.
CREATE_TABLE_SQL = """
CREATE TABLE IF NOT EXISTS raw.{table} (
    -- The entire source row, unmodified, as JSONB. Untyped on purpose:
    -- the mess lives here so dbt staging has something to clean.
    payload     JSONB        NOT NULL,
    -- Loader audit trail: when this row landed. Source-side facts only.
    loaded_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);
"""

TRUNCATE_SQL = "TRUNCATE TABLE raw.{table};"
INSERT_SQL = "INSERT INTO raw.{table} (payload, loaded_at) VALUES (%s, %s);"


# ---------------------------------------------------------------------------
# Parsers: one function per file type. Each yields (payload_dict, error) so
# malformed records can be routed to the dead-letter file, never silently
# swallowed.
# ---------------------------------------------------------------------------
def parse_csv_file(path: Path):
    """Yield dict payloads from a (semicolon-delimited) CSV.

    Why Python-side parsing instead of Postgres COPY:
      COPY expects one consistent column layout, but our files have missing
      fields, nested JSON in `items`, and mixed date strings that must stay
      TEXT in the payload. Row-wise JSONB inserts keep every quirk intact.
    """
    with path.open("r", encoding="utf-8", newline="") as f:
        # delimiter=';' matches generate_data.py — a classic European export
        reader = csv.DictReader(f, delimiter=";")
        for row in reader:
            # DictReader never "fails" a row; missing trailing fields become
            # None which json.dumps turns into null — exactly what we want.
            yield row, None


def parse_jsonl_file(path: Path):
    """Yield parsed JSON per line. Malformed lines yield (None, raw_line)."""
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                yield None, "<empty line>"      # blank lines are defects too
                continue
            try:
                yield json.loads(line), None
            except json.JSONDecodeError:
                yield None, line                # dead-letter candidate


PARSERS = {"csv": parse_csv_file, "jsonl": parse_jsonl_file}


# ---------------------------------------------------------------------------
# Loader core
# ---------------------------------------------------------------------------
def load_table(conn, table: str, path: Path, parse_mode: str) -> dict:
    """Load one file into raw.<table>. Returns {loaded, dead_lettered}."""
    parser = PARSERS[parse_mode]
    batch, dead = [], []
    loaded = 0

    with conn.cursor() as cur:
        for payload, error in parser(path):
            if error is not None:
                dead.append(error)
                continue
            batch.append((json.dumps(payload), datetime.now(timezone.utc)))
            if len(batch) >= BATCH_SIZE:
                cur.executemany(INSERT_SQL.format(table=table), batch)
                loaded += len(batch)
                batch.clear()
        if batch:  # final partial batch
            cur.executemany(INSERT_SQL.format(table=table), batch)
            loaded += len(batch)

    # Dead-letter file: evidence, not silent loss. Mention this in interviews
    # — "bad records go to a dead-letter file and the loader reports counts."
    if dead:
        DEAD_LETTER_DIR.mkdir(parents=True, exist_ok=True)
        dl = DEAD_LETTER_DIR / f"{table}_{datetime.now():%Y%m%d_%H%M%S}.txt"
        dl.write_text("\n".join(dead), encoding="utf-8")
        print(f"      !! {len(dead)} malformed lines -> {dl.name}")
    return {"loaded": loaded, "dead_lettered": len(dead)}


def main() -> None:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    print(f"Connecting to PostgreSQL -> {CONNINFO.split('password=')[0]}...")
    with psycopg.connect(CONNINFO, autocommit=False) as conn:
        with conn.cursor() as cur:
            cur.execute("CREATE SCHEMA IF NOT EXISTS raw;")
            for table in SOURCES:
                cur.execute(CREATE_TABLE_SQL.format(table=table))
                cur.execute(TRUNCATE_SQL.format(table=table))
        conn.commit()

        for table, (filename, mode) in SOURCES.items():
            path = RAW_DIR / filename
            if not path.exists():
                print(f"  [SKIP] {filename} not found — run generate_data.py first")
                continue
            stats = load_table(conn, table, path, mode)
            conn.commit()
            print(f"  [OK ] raw.{table:<10} <- {filename:<15} "
                  f"loaded={stats['loaded']:>7,} "
                  f"dead_lettered={stats['dead_lettered']}")
    print("Raw load complete.")


if __name__ == "__main__":
    sys.exit(main())
