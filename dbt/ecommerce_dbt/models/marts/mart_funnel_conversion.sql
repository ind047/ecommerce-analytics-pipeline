{#
=============================================================================
 mart_funnel_conversion.sql — BUSINESS MART: stage conversion rates
=============================================================================
 GRAIN: one row per funnel stage with cumulative counts and step/overall
 conversion. Consumed by the Power BI funnel visual.

 WHY THIS IS TRIVIAL FROM AN ACCUMULATING SNAPSHOT (interview beat):
 "Because fct_funnel already collapsed each session's journey into one row
  of milestone timestamps, stage counts are COUNT(*) of non-NULL columns
  and conversion rates are simple divisions. The expensive event-sequence
  logic happened once, in the fact; this mart is pure presentation math."
#}
with funnel as (
    select * from {{ ref('fct_funnel') }}
),
stage_counts as (
    select
        count(*)                                   as sessions,
        count(first_viewed_at)                     as viewed,
        count(first_added_at)                      as added_to_cart,
        count(first_checkout_at)                   as checked_out,
        count(first_purchased_at)                  as purchased
    from funnel
),
-- One row per stage, in funnel order. We UNPIVOT the wide count columns
-- into rows with UNION ALL — each arm names its stage explicitly, which is
-- more readable than a conditional unpivot. LAG (in the final select)
-- gives the previous stage's count for step conversion without a self-join.
stages as (
    select 1 as stage_order, 'page_view'   as stage_name, viewed        as stage_count from stage_counts
    union all
    select 2, 'add_to_cart', added_to_cart from stage_counts
    union all
    select 3, 'checkout',    checked_out   from stage_counts
    union all
    select 4, 'purchase',    purchased     from stage_counts
)
select
    stage_order,
    stage_name,
    stage_count,
    lag(stage_count) over (order by stage_order)               as prev_stage_count,
    round(stage_count * 1.0
          / nullif(lag(stage_count) over (order by stage_order), 0), 4)
                                                               as step_conversion_rate,
    round(stage_count * 1.0 / nullif(max(stage_count) over (), 0), 4)
                                                               as overall_conversion_rate
from stages
order by stage_order
