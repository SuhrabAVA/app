alter table if exists public.prod_plan_stages
  add column if not exists stage_group_key text;

update public.prod_plan_stages
set stage_group_key = stage_id
where coalesce(stage_group_key, '') = '';

create index if not exists prod_plan_stages_plan_stage_group_idx
  on public.prod_plan_stages(plan_id, stage_group_key);
