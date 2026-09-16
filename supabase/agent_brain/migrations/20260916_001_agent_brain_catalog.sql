begin;

create extension if not exists pgcrypto with schema extensions;

create or replace function public.ai_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create table public.ai_entities (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  business_name text not null,
  entity_kind text not null check (entity_kind in ('table', 'view', 'function', 'concept')),
  source_schema text,
  source_object text,
  description text not null default '',
  sensitivity text not null default 'internal'
    check (sensitivity in ('public', 'internal', 'personal', 'financial', 'secret')),
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_fields (
  id uuid primary key default gen_random_uuid(),
  entity_id uuid not null references public.ai_entities(id) on delete cascade,
  column_name text not null,
  business_name text not null,
  data_type text,
  description text not null default '',
  unit text,
  allowed_values jsonb not null default '[]'::jsonb,
  sensitivity text not null default 'internal'
    check (sensitivity in ('public', 'internal', 'personal', 'financial', 'secret')),
  pitfalls text[] not null default '{}',
  source_reference text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity_id, column_name)
);

create table public.ai_relationships (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  from_entity_id uuid not null references public.ai_entities(id) on delete cascade,
  to_entity_id uuid not null references public.ai_entities(id) on delete cascade,
  relationship_kind text not null check (relationship_kind in ('foreign_key', 'logical', 'derived')),
  cardinality text not null check (cardinality in ('one_to_one', 'one_to_many', 'many_to_one', 'many_to_many')),
  join_expression text not null,
  description text not null default '',
  confirmed_by_human boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_status_dictionary (
  id uuid primary key default gen_random_uuid(),
  entity_code text not null,
  field_name text not null,
  status_value text not null,
  display_name text not null,
  description text not null default '',
  terminal boolean not null default false,
  aliases text[] not null default '{}',
  source_reference text,
  confirmed_by_human boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (entity_code, field_name, status_value)
);

create table public.ai_terms (
  id uuid primary key default gen_random_uuid(),
  term text not null unique,
  aliases text[] not null default '{}',
  entity_codes text[] not null default '{}',
  definition text not null,
  source_reference text,
  confirmed_by_human boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_business_rules (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null,
  rule_text text not null,
  enforcement_layer text not null
    check (enforcement_layer in ('database', 'dart', 'agent', 'none', 'mixed')),
  severity text not null default 'medium'
    check (severity in ('critical', 'high', 'medium', 'low', 'info')),
  confidence text not null default 'confirmed'
    check (confidence in ('confirmed', 'strong_suspicion', 'heuristic', 'unknown')),
  entity_codes text[] not null default '{}',
  source_references text[] not null default '{}',
  valid_from timestamptz,
  valid_to timestamptz,
  confirmed_by_human boolean not null default false,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_documents (
  id uuid primary key default gen_random_uuid(),
  source_kind text not null check (source_kind in ('code', 'migration', 'documentation', 'human_note')),
  source_path text not null,
  source_hash text,
  title text not null,
  content text not null,
  line_start integer,
  line_end integer,
  entity_codes text[] not null default '{}',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (source_path, source_hash, line_start, line_end)
);

create table public.ai_allowed_objects (
  id uuid primary key default gen_random_uuid(),
  schema_name text not null default 'public',
  object_name text not null,
  object_kind text not null check (object_kind in ('table', 'view', 'function')),
  allowed_operations text[] not null default array['select']::text[],
  sensitive_columns text[] not null default '{}',
  financial_columns text[] not null default '{}',
  requires_golden_query boolean not null default false,
  reason text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (schema_name, object_name, object_kind)
);

create table public.ai_golden_queries (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  topic text not null,
  title text not null,
  sql_template text not null,
  parameter_schema jsonb not null default '{}'::jsonb,
  calculation_notes text not null,
  exclusions text not null default '',
  dependencies jsonb not null default '[]'::jsonb,
  known_limitations text not null default '',
  verified_at timestamptz,
  verified_by text,
  verification_result jsonb,
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_quality_checks (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  title text not null,
  description text not null,
  severity text not null check (severity in ('critical', 'high', 'medium', 'low', 'info')),
  confidence text not null default 'confirmed'
    check (confidence in ('confirmed', 'strong_suspicion', 'heuristic')),
  sql_template text not null,
  schedule text,
  source_rule_codes text[] not null default '{}',
  sample_limit integer not null default 10 check (sample_limit between 0 and 10),
  active boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_eval_cases (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  question text not null,
  expected_behavior text not null check (expected_behavior in ('answer', 'clarify', 'refuse')),
  expected_sql text,
  expected_result jsonb,
  trap_codes text[] not null default '{}',
  notes text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_schema_snapshots (
  id uuid primary key default gen_random_uuid(),
  source_project_ref text not null,
  source_schema text not null default 'public',
  schema_hash text not null,
  schema_payload jsonb not null,
  profile_payload jsonb not null default '{}'::jsonb,
  captured_at timestamptz not null default now(),
  captured_by text,
  unique (source_project_ref, source_schema, schema_hash)
);

create table public.ai_runs (
  id uuid primary key default gen_random_uuid(),
  run_kind text not null check (run_kind in ('inventory', 'audit', 'evaluation', 'drift')),
  status text not null check (status in ('running', 'completed', 'failed', 'cancelled')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  snapshot_id uuid references public.ai_schema_snapshots(id),
  summary jsonb not null default '{}'::jsonb,
  error_text text
);

create table public.ai_findings (
  id uuid primary key default gen_random_uuid(),
  check_id uuid references public.ai_quality_checks(id),
  run_id uuid references public.ai_runs(id) on delete set null,
  fingerprint text not null,
  title text not null,
  description text not null,
  severity text not null check (severity in ('critical', 'high', 'medium', 'low', 'info')),
  confidence text not null check (confidence in ('confirmed', 'strong_suspicion', 'unusual', 'insufficient_data')),
  lifecycle_status text not null default 'new'
    check (lifecycle_status in ('new', 'recurring', 'acknowledged', 'resolved', 'false_positive')),
  affected_count bigint not null default 0 check (affected_count >= 0),
  sample_rows jsonb not null default '[]'::jsonb,
  evidence jsonb not null default '{}'::jsonb,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '90 days'),
  unique (fingerprint, last_seen_at)
);

create table public.ai_query_history (
  id uuid primary key default gen_random_uuid(),
  question text not null,
  user_role text not null,
  plan jsonb,
  sql_text text,
  validator_verdict text not null check (validator_verdict in ('allowed', 'rejected', 'not_generated')),
  rejection_reason text,
  source_snapshot_id uuid references public.ai_schema_snapshots(id),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  row_count bigint check (row_count is null or row_count >= 0),
  result_hash text,
  created_at timestamptz not null default now()
);

create index ai_fields_entity_idx on public.ai_fields(entity_id);
create index ai_rules_entities_gin on public.ai_business_rules using gin(entity_codes);
create index ai_documents_entities_gin on public.ai_documents using gin(entity_codes);
create index ai_findings_status_idx on public.ai_findings(lifecycle_status, severity, last_seen_at desc);
create index ai_query_history_created_idx on public.ai_query_history(created_at desc);
create index ai_runs_started_idx on public.ai_runs(started_at desc);

do $$
declare
  table_name text;
begin
  foreach table_name in array array[
    'ai_entities', 'ai_fields', 'ai_relationships', 'ai_status_dictionary',
    'ai_terms', 'ai_business_rules', 'ai_documents', 'ai_allowed_objects',
    'ai_golden_queries', 'ai_quality_checks', 'ai_eval_cases',
    'ai_schema_snapshots', 'ai_runs', 'ai_findings', 'ai_query_history'
  ]
  loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('revoke all on table public.%I from anon, authenticated', table_name);
    execute format('grant all on table public.%I to service_role', table_name);
  end loop;
end;
$$;

grant usage on schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

create trigger ai_entities_touch before update on public.ai_entities
for each row execute function public.ai_touch_updated_at();
create trigger ai_fields_touch before update on public.ai_fields
for each row execute function public.ai_touch_updated_at();
create trigger ai_relationships_touch before update on public.ai_relationships
for each row execute function public.ai_touch_updated_at();
create trigger ai_status_dictionary_touch before update on public.ai_status_dictionary
for each row execute function public.ai_touch_updated_at();
create trigger ai_terms_touch before update on public.ai_terms
for each row execute function public.ai_touch_updated_at();
create trigger ai_business_rules_touch before update on public.ai_business_rules
for each row execute function public.ai_touch_updated_at();
create trigger ai_documents_touch before update on public.ai_documents
for each row execute function public.ai_touch_updated_at();
create trigger ai_allowed_objects_touch before update on public.ai_allowed_objects
for each row execute function public.ai_touch_updated_at();
create trigger ai_golden_queries_touch before update on public.ai_golden_queries
for each row execute function public.ai_touch_updated_at();
create trigger ai_quality_checks_touch before update on public.ai_quality_checks
for each row execute function public.ai_touch_updated_at();
create trigger ai_eval_cases_touch before update on public.ai_eval_cases
for each row execute function public.ai_touch_updated_at();

commit;
