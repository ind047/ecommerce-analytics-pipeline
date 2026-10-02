{#
=============================================================================
 mart_cohort_retention.sql — BUSINESS MART: monthly cohort retention
=============================================================================
 THE QUERY BEHIND THE CLASSIC RETENTION HEATMAP.

 Narrate this in the interview while writing it:
   1. "Anchor every customer to their acquisition month" (first order).
   2. "Count distinct active customers per cohort per elapsed month."
   3. "Normalize by cohort size" (window MAX over the cohort = month 0).

 months_since uses Postgres's date arithmetic on month boundaries;
 retention_rate = active / cohort_size with month 0 always = 100%.
#}
with first_orders as (
    -- Step 1: acquisition month per customer.
    select
        customer_sk,
        date_trunc('month', min(ordered_at))::date as cohort_month
    from {{ ref('fct_orders') }}
    where revenue > 0
    group by 1
),
activity as (
    -- Step 2: every (customer, activity month) pair with its cohort.
    select
        f.customer_sk,
        f.cohort_month,
        date_trunc('month', o.ordered_at)::date as activity_month
    from first_orders f
    join {{ ref('fct_orders') }} o
      on o.customer_sk = f.customer_sk
     and o.revenue > 0
    group by 1, 2, 3
),
cohort_sizes as (
    -- Cohort size = customers whose FIRST order was in that month.
    select cohort_month, count(*) as cohort_size
    from first_orders
    group by 1
)
select
    a.cohort_month,
    (extract(year  from a.activity_month) - extract(year  from a.cohort_month)) * 12
  + (extract(month from a.activity_month) - extract(month from a.cohort_month))
                                                    as months_since_first,
    count(distinct a.customer_sk)                   as active_customers,
    cs.cohort_size,
    round(count(distinct a.customer_sk) * 1.0 / cs.cohort_size, 4)
                                                    as retention_rate
from activity a
join cohort_sizes cs using (cohort_month)
group by 1, 2, cs.cohort_size
order by 1, 2
