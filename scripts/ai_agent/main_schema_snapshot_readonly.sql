-- Structural snapshot for Easy Pack Pro Contour A.
-- This file contains one SELECT and does not read row contents.
with objects as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', n.nspname,
      'name', c.relname,
      'kind', case c.relkind
        when 'r' then 'table'
        when 'p' then 'partitioned_table'
        when 'v' then 'view'
        when 'm' then 'materialized_view'
      end,
      'rls_enabled', c.relrowsecurity,
      'description', obj_description(c.oid, 'pg_class')
    ) order by c.relname
  ) as payload
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p', 'v', 'm')
), columns as (
  select jsonb_agg(
    jsonb_build_object(
      'table', c.table_name,
      'column', c.column_name,
      'ordinal', c.ordinal_position,
      'data_type', c.data_type,
      'udt_name', c.udt_name,
      'nullable', c.is_nullable = 'YES',
      'default', c.column_default,
      'is_generated', c.is_generated,
      'generation_expression', c.generation_expression,
      'description', col_description(pc.oid, c.ordinal_position)
    ) order by c.table_name, c.ordinal_position
  ) as payload
  from information_schema.columns c
  join pg_namespace pn on pn.nspname = c.table_schema
  join pg_class pc on pc.relnamespace = pn.oid and pc.relname = c.table_name
  where c.table_schema = 'public'
), constraints as (
  select jsonb_agg(
    jsonb_build_object(
      'table', con.conrelid::regclass::text,
      'name', con.conname,
      'type', case con.contype
        when 'p' then 'primary_key'
        when 'f' then 'foreign_key'
        when 'u' then 'unique'
        when 'c' then 'check'
        when 'x' then 'exclusion'
      end,
      'definition', pg_get_constraintdef(con.oid, true)
    ) order by con.conrelid::regclass::text, con.conname
  ) as payload
  from pg_constraint con
  join pg_namespace n on n.oid = con.connamespace
  where n.nspname = 'public'
), indexes as (
  select jsonb_agg(
    jsonb_build_object(
      'table', tablename,
      'name', indexname,
      'definition', indexdef
    ) order by tablename, indexname
  ) as payload
  from pg_indexes
  where schemaname = 'public'
), functions as (
  select jsonb_agg(
    jsonb_build_object(
      'name', p.proname,
      'arguments', pg_get_function_identity_arguments(p.oid),
      'result', pg_get_function_result(p.oid),
      'volatility', case p.provolatile
        when 'i' then 'immutable'
        when 's' then 'stable'
        else 'volatile'
      end,
      'security_definer', p.prosecdef,
      'definition_md5', md5(pg_get_functiondef(p.oid))
    ) order by p.proname, pg_get_function_identity_arguments(p.oid)
  ) as payload
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
), triggers as (
  select jsonb_agg(
    jsonb_build_object(
      'table', event_object_table,
      'name', trigger_name,
      'timing', action_timing,
      'events', event_manipulation,
      'statement', action_statement
    ) order by event_object_table, trigger_name, event_manipulation
  ) as payload
  from information_schema.triggers
  where trigger_schema = 'public'
), policies as (
  select jsonb_agg(
    jsonb_build_object(
      'table', tablename,
      'name', policyname,
      'roles', roles,
      'command', cmd,
      'permissive', permissive,
      'using', qual,
      'with_check', with_check
    ) order by tablename, policyname
  ) as payload
  from pg_policies
  where schemaname = 'public'
), enums as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', n.nspname,
      'name', t.typname,
      'values', e.values
    ) order by n.nspname, t.typname
  ) as payload
  from pg_type t
  join pg_namespace n on n.oid = t.typnamespace
  join lateral (
    select jsonb_agg(en.enumlabel order by en.enumsortorder) as values
    from pg_enum en
    where en.enumtypid = t.oid
  ) e on true
  where n.nspname = 'public'
    and t.typtype = 'e'
), sequences as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', sequence_schema,
      'name', sequence_name,
      'data_type', data_type,
      'start_value', start_value,
      'minimum_value', minimum_value,
      'maximum_value', maximum_value,
      'increment', increment,
      'cycle', cycle_option
    ) order by sequence_schema, sequence_name
  ) as payload
  from information_schema.sequences
  where sequence_schema = 'public'
), extensions as (
  select jsonb_agg(
    jsonb_build_object(
      'name', e.extname,
      'version', e.extversion,
      'schema', n.nspname
    ) order by e.extname
  ) as payload
  from pg_extension e
  join pg_namespace n on n.oid = e.extnamespace
), views as (
  select jsonb_agg(
    jsonb_build_object(
      'schema', schemaname,
      'name', viewname,
      'definition', definition
    ) order by viewname
  ) as payload
  from pg_views
  where schemaname = 'public'
), snapshot as (
  select jsonb_build_object(
    'captured_at', now(),
    'schema', 'public',
    'objects', coalesce(objects.payload, '[]'::jsonb),
    'columns', coalesce(columns.payload, '[]'::jsonb),
    'constraints', coalesce(constraints.payload, '[]'::jsonb),
    'indexes', coalesce(indexes.payload, '[]'::jsonb),
    'functions', coalesce(functions.payload, '[]'::jsonb),
    'triggers', coalesce(triggers.payload, '[]'::jsonb),
    'policies', coalesce(policies.payload, '[]'::jsonb),
    'enums', coalesce(enums.payload, '[]'::jsonb),
    'sequences', coalesce(sequences.payload, '[]'::jsonb),
    'extensions', coalesce(extensions.payload, '[]'::jsonb),
    'views', coalesce(views.payload, '[]'::jsonb)
  ) as payload
  from objects, columns, constraints, indexes, functions, triggers, policies,
       enums, sequences, extensions, views
)
select payload, md5((payload - 'captured_at')::text) as schema_hash
from snapshot;

