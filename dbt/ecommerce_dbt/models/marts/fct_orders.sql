{#
=============================================================================
 fct_orders.sql — ORDER FACT TABLE (transactional fact)
=============================================================================
 FACT TABLE TALKING POINTS:
   * Type: TRANSACTIONAL — one row per order line (the atomic economic
     event). Additive measures (quantity, revenue) aggregate cleanly;
     semi-additive/non-additive measures don't appear at this grain.
   * Keys: surrogate keys of the dims it joins (customer_sk, product_sk).
     Facts should NOT carry natural keys as join columns.
   * Filtering policy: test orders and defective lines are EXCLUDED here.
     The flags were computed in staging; the fact is where the business
     decides what counts. "Revenue" below = completed orders only.
   * Degenerate dimension: order_id stays on the fact (it has no dim of
     its own) — that is exactly what degenerate dimensions are.
#}
with lines as (
    select * from {{ ref('stg_orders') }}
),
customers as (
    select customer_sk, customer_id from {{ ref('dim_customers') }}
),
products as (
    select product_sk, product_id from {{ ref('dim_products') }}
)
select
    c.customer_sk,
    p.product_sk,
    l.order_id,                       -- degenerate dimension
    l.line_no,
    l.ordered_at,
    l.status,
    l.quantity,
    l.unit_price,
    l.line_total,
    -- Revenue measure, defined ONCE: completed, non-defective lines only.
    -- Every KPI downstream references THIS column, not a re-computation.
    case when l.status = 'completed' then l.line_total else 0 end as revenue
from lines l
join customers c on c.customer_id = l.customer_id
join products  p on p.product_id  = l.product_id
where l.is_real_order              -- business filter, decided at the fact
  and l.is_valid_line              -- data-quality filter, decided at staging
