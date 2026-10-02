{#
=============================================================================
 fct_events.sql — EVENT FACT TABLE (transactional fact)
=============================================================================
 Grain: one row per clickstream event. Facts can be more than money —
 any measurable event at a declared grain belongs in a fact table.
 Kept deliberately narrow: session analytics lives in fct_funnel, so this
 fact is the raw material, not the answer.
#}
select
    {{ dbt_utils.surrogate_key(['event_id']) }} as event_sk,
    c.customer_sk,
    p.product_sk,
    e.event_id,
    e.session_id,
    e.event_type,
    e.page_url,
    e.event_at
from {{ ref('stg_events') }} e
join {{ ref('dim_customers') }} c on c.customer_id = e.customer_id
left join {{ ref('dim_products') }} p on p.product_id = e.product_id
where e.is_canonical          -- only the four canonical funnel events
