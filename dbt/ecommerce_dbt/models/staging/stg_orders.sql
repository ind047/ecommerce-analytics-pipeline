{#
=============================================================================
 stg_orders.sql — staging: orders cleaned, flattened, deduplicated
=============================================================================
 THE HARD PARTS, EXPLAINED:
   1. Mixed date formats  -> same regex-detect + to_timestamp strategy as
      stg_customers. Centralizing the pattern in every staging model (rather
      than one macro) is deliberate for learning; production would extract
      a macro like {{ parse_mixed_timestamp('created_at') }}.
   2. Nested line items   -> payload -> 'items' is a JSON ARRAY STRING.
      We explode it with jsonb_array_elements + ordinality so ONE order
      becomes N rows of (order_id, line_no, product_id, quantity, price).
      Grain statement: one row per order line — the grain declaration that
      every downstream column must respect.
   3. Test orders         -> kept with a flag, not dropped. Staging keeps
      everything; the mart decides the filter. That's the layering contract.
   4. Negative quantities -> kept, but the line is flagged. Revenue marts
      filter on is_valid so defects can't pollute KPIs.
#}
with source_data as (
    select
        (payload ->> 'order_id')::bigint      as order_id,
        (payload ->> 'customer_id')::int      as customer_id,
        payload ->> 'status'                  as status_raw,
        (payload ->> 'total_amount')::numeric as total_amount_raw,
        payload ->> 'items'                   as items_raw,
        case
            when payload ->> 'created_at' ~ '^\d{4}-\d{2}-\d{2}'
                then (payload ->> 'created_at')::timestamp
            when payload ->> 'created_at' ~ '^\d{2}/\d{2}/\d{4}'
                then to_timestamp(payload ->> 'created_at', 'DD/MM/YYYY HH24:MI')
            when payload ->> 'created_at' ~ '^\d+$'
                then to_timestamp((payload ->> 'created_at')::bigint)
            else null
        end                                   as ordered_at
    from {{ source('raw', 'orders') }}
    where payload ->> 'order_id' is not null
),
-- ---------------------------------------------------------------------------
-- Explode the nested items array. WITH ORDINALITY gives us line_no, the
-- position of each element inside its array — the natural order-line key.
-- jsonb_array_elements requires a jsonb cast: the text is valid JSON by
-- construction (the generator wrote it with json.dumps).
-- ---------------------------------------------------------------------------
lines as (
    select
        s.order_id,
        s.customer_id,
        s.ordered_at,
        lower(trim(s.status_raw))                      as status,
        s.total_amount_raw,
        ord.line_no,
        (ord.item ->> 'product_id')::int               as product_id,
        (ord.item ->> 'quantity')::int                 as quantity,
        (ord.item ->> 'unit_price')::numeric           as unit_price
    from source_data s,
    lateral jsonb_array_elements(s.items_raw::jsonb)
        with ordinality as ord(item, line_no)
),
-- Business-rule flags: staging computes them, marts consume them.
flagged as (
    select
        order_id, line_no, customer_id, ordered_at,
        product_id, quantity, unit_price,
        status,
        (status <> 'test')                          as is_real_order,
        (quantity > 0 and unit_price > 0)           as is_valid_line,
        round(quantity * unit_price, 2)             as line_total
    from lines
),
deduplicated as (
    select
        *,
        row_number() over (
            partition by order_id, line_no
            order by ordered_at desc
        ) as rn
    from flagged
)
select
    order_id, line_no, customer_id, ordered_at, product_id,
    quantity, unit_price, line_total, status, is_real_order, is_valid_line
from deduplicated
where rn = 1
