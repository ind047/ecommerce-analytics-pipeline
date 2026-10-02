-- ============================================================================
-- singular test: no_orphan_order_lines.sql
-- The generic relationships test already guards customer_id/product_id.
-- This test adds a BUSINESS invariant: every real order's line total must
-- be positive. If negative quantities ever leak past the is_valid_line
-- flag into revenue math, this test fails the build.
-- ============================================================================
select order_id, line_no, quantity, unit_price
from {{ ref('stg_orders') }}
where is_valid_line
  and line_total <= 0
