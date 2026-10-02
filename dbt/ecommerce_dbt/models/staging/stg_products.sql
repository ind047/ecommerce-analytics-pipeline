{#
=============================================================================
 stg_products.sql — staging: cleaned product catalog
=============================================================================
 Key cleaning rules demonstrated:
   * duplicate product_id rows   -> ROW_NUMBER dedup
   * zero-price outliers          -> NULL (price unknown beats price=0 lying)
   * missing category             -> 'Unknown' (explicit beats NULL for BI)
#}
with source_data as (
    select
        (payload ->> 'product_id')::int   as product_id,
        payload ->> 'product_name'        as product_name_raw,
        payload ->> 'category'            as category_raw,
        (payload ->> 'price')::numeric    as price_raw,
        payload ->> 'supplier'            as supplier_raw
    from {{ source('raw', 'products') }}
    where payload ->> 'product_id' is not null
),
standardized as (
    select
        product_id,
        trim(product_name_raw)                              as product_name,
        -- NULLIF converts empty strings to NULL; COALESCE then makes the
        -- gap explicit for report consumers ('Unknown' shows in filters).
        coalesce(nullif(trim(category_raw), ''), 'Unknown') as category,
        -- Outlier policy: price <= 0 is a data defect, not a real price.
        -- Setting it NULL (not 0) keeps AVG(price) honest.
        nullif(price_raw, 0)                                as unit_price,
        trim(supplier_raw)                                  as supplier
    from source_data
),
deduplicated as (
    select
        product_id, product_name, category, unit_price, supplier,
        row_number() over (
            partition by product_id
            order by product_name
        ) as rn
    from standardized
)
select product_id, product_name, category, unit_price, supplier
from deduplicated
where rn = 1
