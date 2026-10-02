{# ============================================================================
 generate_schema_name.sql — CUSTOM schema naming logic
============================================================================
 THE GOTCHA THIS FIXES (a favorite interview question):
   By default, dbt builds a model with `+schema: marts` into
   "<target_schema>_<custom_schema>" — i.e. schema `dbt_marts`, not `marts`.
   That default exists so teams can share one database without collisions.

   For this portfolio we WANT clean top-level schemas (raw / staging /
   marts) exactly as the architecture diagram shows. Overriding
   generate_schema_name to return the custom schema name unchanged gives
   us that. In production you'd more likely keep the prefix (env isolation)
   or switch behavior per target:

       {{ generate_schema_name(custom_schema_name, node) }}
       -> 'marts' in dev when custom_schema_name is set

   If an interviewer asks "why is your staging schema called staging and
   not dbt_staging?" — this macro is the answer.
#}}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
