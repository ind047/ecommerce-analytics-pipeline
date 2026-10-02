-- ============================================================================
-- singular test: funnel_milestones_in_order.sql
-- Business invariant on the accumulating snapshot: a session can only
-- REACH a later milestone after the earlier ones. Any row where, say,
-- checkout precedes the first page view indicates timestamp corruption
-- and must fail the build.
-- ============================================================================
select session_id, first_viewed_at, first_added_at, first_checkout_at, first_purchased_at
from {{ ref('fct_funnel') }}
where (first_added_at     is not null and first_added_at     < first_viewed_at)
   or (first_checkout_at  is not null and first_checkout_at  < coalesce(first_added_at, first_viewed_at))
   or (first_purchased_at is not null and first_purchased_at < coalesce(first_checkout_at, first_added_at, first_viewed_at))
