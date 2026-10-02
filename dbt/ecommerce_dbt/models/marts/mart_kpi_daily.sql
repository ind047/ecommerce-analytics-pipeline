{#
=============================================================================
 mart_kpi_daily.sql — BUSINESS MART: daily KPI summary
=============================================================================
 GRAIN: one row per calendar day. This is the table the Power BI KPI card
 and trend charts bind to — narrow, pre-aggregated, fast.

 DESIGN PRINCIPLE (interview beat): every measure is defined ONCE, in SQL,
 upstream of the BI tool. Power BI's DAX then only does presentation
 formatting. "Revenue" is marts.fct_orders.revenue — not a DAX measure
 re-implemented five ways in five reports.
#}
with orders as (
    select * from {{ ref('fct_orders') }}
),
daily as (
    select
        ordered_at::date                          as order_date,
        count(distinct order_id)                  as orders,
        count(distinct customer_sk)               as buying_customers,
        sum(quantity)                             as units_sold,
        round(sum(revenue), 2)                    as revenue,
        -- Average order value = revenue / distinct orders, NOT
        -- avg(line_total): the fact is at LINE grain, so a naive avg()
        -- would weight lines, not orders.
        round(sum(revenue) / nullif(count(distinct order_id), 0), 2) as aov
    from orders
    where revenue > 0          -- days with only cancelled/returned lines
    group by 1                  -- are excluded; a day without revenue is
)                               -- not a KPI day
select
    d.*,
    -- Week-over-week revenue trend, computed with a window function so the
    -- BI tool gets it for free. lag() avoids a self-join.
    round(revenue - lag(revenue) over (order by order_date), 2) as revenue_wow_change
from daily d
order by order_date
