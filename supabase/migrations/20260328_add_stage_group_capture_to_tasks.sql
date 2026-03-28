alter table if exists public.tasks
  add column if not exists stage_group_key text,
  add column if not exists captured_by_workplace_id text,
  add column if not exists captured_by_user_id text,
  add column if not exists captured_at bigint;

update public.tasks
set stage_group_key = stage_id
where coalesce(stage_group_key, '') = '';

create index if not exists tasks_order_stage_group_idx
  on public.tasks(order_id, stage_group_key);
