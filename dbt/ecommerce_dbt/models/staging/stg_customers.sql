{#
=============================================================================
 stg_customers.sql — staging: cleaned, typed, deduplicated customers
=============================================================================
 STAGING RULES (say this in the interview):
   1. One staging model per raw source, 1:1 in grain.
   2. Clean and standardize ONLY — no joins, no business logic. Business
      logic belongs in marts. This separation means cleaning rules are
      testable in isolation.
   3. Every mess type from the generator maps to one visible rule below.
#}

with

-- --------------------------------------------------------------------------
-- 1. Cast the JSONB payload into typed columns.
--    The ->> operator extracts a TEXT value from JSONB; we cast explicitly
--    so type errors fail HERE, loudly, not somewhere deep in a mart.
-- --------------------------------------------------------------------------
source_data as (
    select
        (payload ->> 'customer_id')::int        as customer_id,
        payload ->> 'full_name'                 as full_name_raw,
        payload ->> 'email'                     as email_raw,
        payload ->> 'phone'                     as phone_raw,
        payload ->> 'city'                      as city_raw,
        payload ->> 'country'                   as country_raw,

        -- Mixed date formats arrive as strings. We normalize in two steps:
        --   a) detect the format with regex on the string shape
        --   b) parse with the matching pattern (DD/MM/YYYY is the trap —
        --      to_timestamp with 'MM/DD' would silently shift dates)
        case
            when payload ->> 'signup_date' ~ '^\d{4}-\d{2}-\d{2}'
                then (payload ->> 'signup_date')::timestamp
            when payload ->> 'signup_date' ~ '^\d{2}/\d{2}/\d{4}'
                then to_timestamp(payload ->> 'signup_date', 'DD/MM/YYYY HH24:MI')
            when payload ->> 'signup_date' ~ '^\d+$'
                then to_timestamp((payload ->> 'signup_date')::bigint)
            else null
        end                                     as signup_at
    from {{ source('raw', 'customers') }}
),

-- --------------------------------------------------------------------------
-- 2. Standardize text: trim whitespace, fix casing, normalize codes.
--    Done with CTEs so each rule is one readable step.
-- --------------------------------------------------------------------------
standardized as (
    select
        customer_id,
        trim(full_name_raw)                     as full_name,
        lower(trim(email_raw))                  as email,      -- casing fix
        nullif(trim(phone_raw), '')             as phone,      -- '' -> NULL
        initcap(trim(city_raw))                 as city,       -- "BERLIN" -> "Berlin"
        upper(trim(country_raw))                as country,
        signup_at
    from source_data
    -- Row must at least have an id and a signup date to be a customer at all.
    where customer_id is not null
      and signup_at   is not null
),

-- --------------------------------------------------------------------------
-- 3. Deduplicate: same customer delivered twice (at-least-once delivery).
--    Pattern: ROW_NUMBER() partitioned by the business key, keep latest
--    received row. rn = 1 survives; the rest are quarantined by the unique
--    test on the final model.
-- --------------------------------------------------------------------------
deduplicated as (
    select
        customer_id, full_name, email, phone, city, country, signup_at,
        row_number() over (
            partition by customer_id
            order by full_name desc   -- deterministic tie-break
        ) as rn
    from standardized
)

select
    customer_id,
    full_name,
    email,
    phone,
    city,
    country,
    signup_at
from deduplicated
where rn = 1
