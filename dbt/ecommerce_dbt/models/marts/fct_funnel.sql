{#
=============================================================================
 fct_funnel.sql — ACCUMULATING SNAPSHOT FACT
=============================================================================
 THE STAR OF THE MODELING STORY. One row per session, with ONE DATE
 COLUMN PER FUNNEL MILESTONE (first page_view / add_to_cart / checkout /
 purchase). That is the textbook definition of an accumulating snapshot.

 WHY IT'S POWERFUL (interview answer):
   * "Conversion between stages is a COUNT of non-NULL milestones divided by
      the previous stage's count."
   * "Time between stages is a DATEDIFF between two columns on the SAME row
      — no event-sequence self-joins, no LAG() gymnastics."
   * "It's update-friendly: as a session matures, its single row fills in
      more milestone timestamps" (in our batch rebuild it is rebuilt, but
      the modeling point stands).
#}
with events as (
    select * from {{ ref('fct_events') }}
),
-- Pivot events into one row per session: min() captures each milestone's
-- FIRST occurrence — the moment the session entered that stage.
milestones as (
    select
        session_id,
        customer_sk,
        min(event_at) filter (where event_type = 'page_view')   as first_viewed_at,
        min(event_at) filter (where event_type = 'add_to_cart') as first_added_at,
        min(event_at) filter (where event_type = 'checkout')    as first_checkout_at,
        min(event_at) filter (where event_type = 'purchase')    as first_purchased_at
    from events
    group by 1, 2
)
select
    {{ dbt_utils.surrogate_key(['session_id']) }} as session_sk,
    session_id,
    customer_sk,
    first_viewed_at,
    first_added_at,
    first_checkout_at,
    first_purchased_at,
    -- Pre-computed stage intervals (minutes). Same-row DATEDIFFs are the
    -- accumulating snapshot's superpower.
    round(extract(epoch from (first_added_at    - first_viewed_at))  / 60, 1) as mins_view_to_cart,
    round(extract(epoch from (first_checkout_at - first_added_at))   / 60, 1) as mins_cart_to_checkout,
    round(extract(epoch from (first_purchased_at - first_checkout_at))/ 60, 1) as mins_checkout_to_purchase
from milestones
where first_viewed_at is not null   -- every session starts with a view
