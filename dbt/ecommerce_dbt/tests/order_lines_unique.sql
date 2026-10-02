-- ============================================================================
-- singular test: order_lines_unique.sql
-- Generic dbt tests operate on ONE column. Our declared grain is
-- (order_id, line_no), so uniqueness of the COMBINATION needs a custom
-- query-based test: the test PASSES when it returns ZERO rows.
-- Interview line: "a singular test is just SQL that returns violations."
-- ============================================================================
select order_id, line_no, count(*) as n_lines
from {{ ref('stg_orders') }}
group by 1, 2
having count(*) > 1
