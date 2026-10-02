{#
=============================================================================
 stg_events.sql — staging: clickstream events normalized
=============================================================================
 Key cleaning rules:
   1. Inconsistent event types ("pageview", "Page_View", "  ADD_TO_CART ")
      -> lower(trim(...)) then map known synonyms back to the canonical 4.
   2. Unknown types are KEPT with a flag rather than dropped — in the
      interview: "we don't silently throw away unknown values; we isolate
      them so a data bug becomes visible as a flag column spike."
   3. Mixed date formats -> same detect-and-parse strategy as orders.
   4. Malformed lines never reach raw (loader dead-letters them), so the
      event_id unique test should pass — that is the pipeline contract.
#}
with source_data as (
    select
        payload ->> 'event_id'                    as event_id,
        (payload ->> 'customer_id')::int          as customer_id,
        payload ->> 'session_id'                  as session_id,
        lower(trim(payload ->> 'event_type'))     as event_type_raw,
        nullif(payload ->> 'product_id', '')::int as product_id,
        payload ->> 'page_url'                    as page_url,
        case
            when payload ->> 'created_at' ~ '^\d{4}-\d{2}-\d{2}'
                then (payload ->> 'created_at')::timestamp
            when payload ->> 'created_at' ~ '^\d{2}/\d{2}/\d{4}'
                then to_timestamp(payload ->> 'created_at', 'DD/MM/YYYY HH24:MI')
            when payload ->> 'created_at' ~ '^\d+$'
                then to_timestamp((payload ->> 'created_at')::bigint)
            else null
        end                                       as event_at
    from {{ source('raw', 'events') }}
    where payload ->> 'event_id' is not null
),
canonicalized as (
    select
        event_id, customer_id, session_id, event_at, product_id, page_url,
        -- Synonym map back to the canonical four funnel events.
        case event_type_raw
            when 'pageview'      then 'page_view'
            when 'page_view'     then 'page_view'
            when 'addtocart'     then 'add_to_cart'
            when 'add_to_cart'   then 'add_to_cart'
            when 'checkout'      then 'checkout'
            when 'purchase'      then 'purchase'
            else event_type_raw
        end as event_type,
        -- accepted_values test on event_type relies on this flag being FALSE
        -- for anything outside the canonical set.
        (event_type_raw in ('pageview', 'page_view', 'addtocart',
                            'add_to_cart', 'checkout', 'purchase')) as is_canonical
    from source_data
),
deduplicated as (
    select
        *,
        row_number() over (
            partition by event_id
            order by event_at
        ) as rn
    from canonicalized
    where event_at is not null   -- an event without a timestamp is unusable
)
select
    event_id, customer_id, session_id, event_type, is_canonical,
    product_id, page_url, event_at
from deduplicated
where rn = 1
