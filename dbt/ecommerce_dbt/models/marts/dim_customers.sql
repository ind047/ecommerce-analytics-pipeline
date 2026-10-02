{#
=============================================================================
 dim_customers.sql — CUSTOMER DIMENSION (SCD Type 1)
=============================================================================
 DIMENSIONAL MODELING TALKING POINTS:
   * Grain: one row per customer (surrogate key + natural key as a column).
   * SCD Type 1: attributes are OVERWRITTEN on change — history is not
     preserved. Defensible here because we never ask "what was the
     customer's city at purchase time?". If we did -> Type 2 with
     dbt snapshots (valid_from / valid_to / is_current).
   * Surrogate key: dbt_utils.surrogate_key hashes the natural key. It
     decouples the warehouse from source-system renumbering and is the join
     column facts use. (dbt 1.8+ also ships a built-in `generate_surrogate_key`.)
#}
with customers as (
    select * from {{ ref('stg_customers') }}
),
orders as (
    select * from {{ ref('stg_orders') }}
),
-- First-order enrichment: customer dimensions often carry "first order
-- date" because acquisition cohorts are defined by it.
first_orders as (
    select
        customer_id,
        min(ordered_at) as first_order_at
    from orders
    where is_real_order and is_valid_line
    group by 1
)
select
    {{ dbt_utils.surrogate_key(['c.customer_id']) }}   as customer_sk,
    c.customer_id,                                      -- natural key kept + tested
    c.full_name,
    c.email,
    c.city,
    c.country,
    c.signup_at,
    f.first_order_at,
    -- Derived attribute: was the customer acquired BEFORE ever ordering?
    (f.first_order_at is null)                         as is_registered_only
from customers c
left join first_orders f using (customer_id)
