#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
=============================================================================
 generate_data.py — deliberately messy e-commerce source data
=============================================================================
 WHY THIS FILE EXISTS (interview narrative):
   Real source systems are not clean CSVs. Fields are missing, dates arrive
   in five formats, event types are spelled inconsistently, and the same
   event is delivered twice. This generator reproduces that reality on
   purpose, so the pipeline downstream (loader -> dbt staging) has something
   genuinely worth cleaning. In the interview: "I generated messy raw data
   so every cleaning rule in staging is justified by a real data defect."

 WHAT IT PRODUCES (written to ../data/raw relative to this file):
   events.jsonl      one JSON object per line (~80k event logs)
   orders.csv        orders with 1-3 line items each, semicolon-delimited,
                     mixed date formats, occasional negative/garbage rows
   customers.csv     customer master data with duplicates & missing fields
   products.csv      product catalog with duplicates & price outliers

 THE MESS, BY DESIGN (each maps to a cleaning rule in dbt staging):
   1. Missing values            -> nulls in optional fields (phone, category)
   2. Duplicates                -> same order/event/customer delivered twice
   3. Mixed date formats        -> ISO, DD/MM/YYYY, and Unix epoch strings
   4. Inconsistent enum values  -> "pageview", "Page_View", " add_to_cart "
   5. Malformed lines           -> a few lines in JSONL are not valid JSON
   6. Outliers / garbage        -> negative quantities, zero-price products,
                                   test orders flagged with status "test"
   7. Inconsistent casing/whitespace in emails, cities, categories

 DETERMINISM:
   A fixed random seed means every run produces the SAME dataset. That makes
   the pipeline reproducible end-to-end and makes interview demos repeatable.
=============================================================================
"""

from __future__ import annotations

import csv
import json
import random
import sys
from datetime import datetime, timedelta
from pathlib import Path

from faker import Faker

# ----------------------------------------------------------------------------
# 0. Configuration — all knobs in one place so the DAG can override them
# ----------------------------------------------------------------------------
SEED = 42                      # fixed seed = reproducible "source system"
N_CUSTOMERS = 1_200            # customers in the master data
N_PRODUCTS = 300               # products in the catalog
N_ORDERS = 20_000              # orders over the activity window
N_EVENTS = 80_000              # raw clickstream events
ACTIVITY_DAYS = 365            # how far back data starts
MALFORMED_LINE_RATE = 0.002    # ~0.2% of JSONL lines are garbage
DUPLICATE_RATE = 0.01          # ~1% of records duplicated
MISSING_FIELD_RATE = 0.03      # ~3% chance an optional field is dropped
TEST_ORDER_RATE = 0.005        # ~0.5% of orders are "test" orders

# Resolve output dir: <project_root>/data/raw regardless of where we run from
PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_DIR = PROJECT_ROOT / "data" / "raw"

CATEGORIES = [
    "Electronics", "Home & Kitchen", "Sports", "Books", "Toys",
    "Clothing", "Beauty", "Groceries",
]

COUNTRIES = ["DE", "AT", "CH", "NL", "FR"]

EVENT_TYPES = ["page_view", "add_to_cart", "checkout", "purchase"]

# ---------------------------------------------------------------------------
# Small helper functions — each one implements ONE kind of mess.
# Keeping them tiny and named makes the defects explicit and testable.
# ---------------------------------------------------------------------------
def maybe_missing(rng: random.Random, value, rate: float = MISSING_FIELD_RATE):
    """With `rate` probability, drop a field entirely (simulates source
    systems that omit keys instead of sending nulls)."""
    return None if rng.random() < rate else value


def messy_date(rng: random.Random, dt: datetime) -> str:
    """Render one datetime in ONE OF THREE formats at random.
    Downstream, dbt staging must handle all three — this is intentional."""
    fmt = rng.choice(["iso", "eu", "epoch"])
    if fmt == "iso":
        return dt.strftime("%Y-%m-%dT%H:%M:%S")          # 2025-03-01T14:22:05
    if fmt == "eu":
        return dt.strftime("%d/%m/%Y %H:%M")              # 01/03/2025 14:22 (ambiguous!)
    return str(int(dt.timestamp()))                        # 1740834125 (epoch string)


def messy_event_type(rng: random.Random, clean_type: str) -> str:
    """Produce inconsistent spellings of the same logical event type."""
    style = rng.random()
    if style < 0.55:
        return clean_type                                 # already clean
    if style < 0.75:
        return clean_type.replace("_", "")                # "pageview"
    if style < 0.90:
        return clean_type.title().replace("_", "_")       # "Page_View"
    return "  " + clean_type.upper() + " "                # "  ADD_TO_CART "


def inject_duplicate(rng: random.Random, rows: list) -> list:
    """Duplicate ~DUPLICATE_RATE of the rows, appending copies at the end.
    Simulates at-least-once delivery from a message queue."""
    dupes = [r for r in rows if rng.random() < DUPLICATE_RATE]
    return rows + dupes


# ---------------------------------------------------------------------------
# 1. Customers — master data with duplicates and missing contact fields
# ---------------------------------------------------------------------------
def gen_customers(rng: random.Random, fake: Faker) -> list[dict]:
    rows = []
    for i in range(N_CUSTOMERS):
        rows.append({
            # ~2% of rows repeat a previous customer_id -> duplicate delivery
            "customer_id": rng.randint(1, N_CUSTOMERS - 20)
                           if rng.random() < 0.02 else i + 1,
            "full_name": fake.name(),
            "email": maybe_missing(rng, fake.email().upper()
                                   if rng.random() < 0.3
                                   else fake.email().lower()),
            "phone": maybe_missing(rng, fake.phone_number()),
            "city": fake.city().upper() if rng.random() < 0.25 else fake.city(),
            "country": rng.choice(COUNTRIES),
            "signup_date": messy_date(rng, fake.date_time_between(
                start_date="-2y", end_date="now")),
        })
    return inject_duplicate(rng, rows)


# ---------------------------------------------------------------------------
# 2. Products — catalog with category gaps and price outliers
# ---------------------------------------------------------------------------
def gen_products(rng: random.Random, fake: Faker) -> list[dict]:
    rows = []
    for i in range(N_PRODUCTS):
        price = round(rng.uniform(5, 500), 2)
        rows.append({
            "product_id": rng.randint(1, N_PRODUCTS - 10)
                          if rng.random() < 0.02 else i + 1,   # dup ids
            "product_name": fake.catch_phrase(),
            "category": maybe_missing(rng, rng.choice(CATEGORIES)),
            "price": price if rng.random() > 0.01 else 0.00,  # ~1% zero price
            "supplier": fake.company(),
        })
    return inject_duplicate(rng, rows)


# ---------------------------------------------------------------------------
# 3. Orders — CSV with mixed date formats, test rows, negative quantities
# ---------------------------------------------------------------------------
def gen_orders(rng: random.Random, fake: Faker, start: datetime) -> list[dict]:
    rows = []
    for i in range(N_ORDERS):
        created = fake.date_time_between(start_date=start, end_date="now")
        n_items = rng.choices([1, 2, 3], weights=[70, 22, 8])[0]
        items = []
        for _ in range(n_items):
            qty = rng.randint(1, 4)
            if rng.random() < 0.005:
                qty = -qty                                   # data-entry bug
            items.append({
                "product_id": rng.randint(1, N_PRODUCTS),
                "quantity": qty,
                "unit_price": round(rng.uniform(5, 500), 2),
            })
        total = sum(it["quantity"] * it["unit_price"] for it in items)
        status = "test" if rng.random() < TEST_ORDER_RATE else rng.choice(
            ["completed", "completed", "completed", "completed",
             "cancelled", "returned"])
        rows.append({
            "order_id": 100000 + i,
            "customer_id": rng.randint(1, N_CUSTOMERS),
            "created_at": messy_date(rng, created),
            "status": status,
            "items": json.dumps(items),                      # nested line items
            "total_amount": round(total, 2) if total > 0 else 0,
            "discount_code": maybe_missing(rng, rng.choice(
                ["SAVE10", "WELCOME", "BLACKFRIDAY"])),
        })
    return inject_duplicate(rng, rows)


# ---------------------------------------------------------------------------
# 4. Events — JSONL clickstream, mostly-funnel-shaped sequences
# ---------------------------------------------------------------------------
def gen_events(rng: random.Random, fake: Faker, start: datetime) -> list[str]:
    """Return RAW FILE LINES (strings), not dicts — we must be able to write
    lines that are not valid JSON at all."""
    lines: list[str] = []
    for i in range(N_EVENTS):
        created = fake.date_time_between(start_date=start, end_date="now")
        customer_id = rng.randint(1, N_CUSTOMERS)
        session_id = f"sess_{rng.randint(1, N_ORDERS // 2)}"
        # Weight event types so funnels look realistic (many views,
        # fewer purchases) — a funnel built on uniform data looks fake.
        event_type = rng.choices(
            EVENT_TYPES, weights=[62, 20, 11, 7])[0]
        event = {
            "event_id": f"evt_{i:07d}",
            "customer_id": customer_id,
            "session_id": session_id,
            "event_type": messy_event_type(rng, event_type),
            "product_id": maybe_missing(rng, rng.randint(1, N_PRODUCTS),
                                        rate=0.15),          # views often lack it
            "page_url": maybe_missing(rng, fake.uri_path()),
            "created_at": messy_date(rng, created),
            "user_agent": maybe_missing(rng, fake.user_agent()),
        }
        lines.append(json.dumps(event))

    # --- inject malformed lines: truncated JSON, wrong types, empty lines ---
    n_bad = int(len(lines) * MALFORMED_LINE_RATE)
    for idx in rng.sample(range(len(lines)), n_bad):
        lines[idx] = rng.choice([
            '{"event_id": "evt_broken", "customer_id": ',     # truncated
            'not json at all {{{',                            # garbage
            '',                                               # empty line
            '{"event_id": 123, "customer_id": "oops"}',       # wrong types
        ])
    return lines


# ---------------------------------------------------------------------------
# 5. Writers
# ---------------------------------------------------------------------------
def write_csv(path: Path, rows: list[dict]) -> None:
    """Write a list of dicts as CSV. Semicolon delimiter is intentional —
    European exports often are ';'-separated, which is its own loader bug
    class to handle and mention in the interview."""
    with path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()),
                                delimiter=";")
        writer.writeheader()
        writer.writerows(rows)


def write_jsonl(path: Path, lines: list[str]) -> None:
    with path.open("w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
def main() -> None:
    RAW_DIR.mkdir(parents=True, exist_ok=True)
    rng = random.Random(SEED)
    fake = Faker(["de_DE"])          # German-flavored data (DEVDEER is German)
    Faker.seed(SEED)                  # keep faker itself deterministic too

    start = datetime.now() - timedelta(days=ACTIVITY_DAYS)

    print(f"[1/4] customers  -> {RAW_DIR / 'customers.csv'}")
    write_csv(RAW_DIR / "customers.csv", gen_customers(rng, fake))
    print(f"[2/4] products   -> {RAW_DIR / 'products.csv'}")
    write_csv(RAW_DIR / "products.csv", gen_products(rng, fake))
    print(f"[3/4] orders     -> {RAW_DIR / 'orders.csv'}")
    write_csv(RAW_DIR / "orders.csv", gen_orders(rng, fake, start))
    print(f"[4/4] events     -> {RAW_DIR / 'events.jsonl'}")
    write_jsonl(RAW_DIR / "events.jsonl", gen_events(rng, fake, start))
    print("Done. Raw data is intentionally messy — that is the point.")


if __name__ == "__main__":
    sys.exit(main())
