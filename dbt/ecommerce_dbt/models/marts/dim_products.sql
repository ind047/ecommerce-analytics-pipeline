{#
=============================================================================
 dim_products.sql — PRODUCT DIMENSION (SCD Type 1)
=============================================================================
 Grain: one row per product. Descriptive attributes only; nothing that
 changes per transaction belongs here (price history would need SCD2).
#}
select
    {{ dbt_utils.surrogate_key(['product_id']) }} as product_sk,
    product_id,                                    -- natural key
    product_name,
    category,
    unit_price,
    supplier
from {{ ref('stg_products') }}
