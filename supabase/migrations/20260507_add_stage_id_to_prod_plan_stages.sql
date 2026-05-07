alter table if exists public.prod_plan_stages
  add column if not exists stage_id text;

do $$
declare
  source_column text;
begin
  select column_name
  into source_column
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'prod_plan_stages'
    and column_name in ('workplace_id', 'workplaceId', 'id')
    and data_type in ('text', 'character varying', 'character')
  order by case column_name
    when 'workplace_id' then 1
    when 'workplaceId' then 2
    when 'id' then 3
  end
  limit 1;

  if source_column is not null then
    execute format(
      'update public.prod_plan_stages
       set stage_id = %1$I
       where coalesce(stage_id, '''') = ''''
         and coalesce(%1$I, '''') <> ''''',
      source_column
    );
  end if;
end $$;

create index if not exists prod_plan_stages_plan_stage_idx
  on public.prod_plan_stages(plan_id, stage_id);

update public.prod_plan_stages
set stage_group_key = stage_id
where coalesce(stage_group_key, '') = ''
  and coalesce(stage_id, '') <> '';

notify pgrst, 'reload schema';
