-- Align paints_writeoffs.paint_id with public.paints.id so paint queue RPC
-- comparisons/inserts use one canonical paint id type end-to-end.

do $$
declare
  v_paint_id_type text;
  v_writeoffs_paint_id_type text;
  v_invalid_count bigint := 0;
begin
  select format_type(a.atttypid, a.atttypmod)
    into v_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints'
     and a.attname = 'id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_paint_id_type is null then
    raise exception 'public.paints.id column was not found';
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into v_writeoffs_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints_writeoffs'
     and a.attname = 'paint_id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_writeoffs_paint_id_type is null then
    raise exception 'public.paints_writeoffs.paint_id column was not found';
  end if;

  execute 'drop function if exists public.safe_paint_id(text)';
  if v_paint_id_type = 'uuid' then
    execute $sql$
      create function public.safe_paint_id(p_value text)
      returns uuid
      language sql
      immutable
      as $fn$
        select case
          when nullif(trim(p_value), '') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
            then nullif(trim(p_value), '')::uuid
          else null
        end
      $fn$
    $sql$;
  else
    execute format($sql$
      create function public.safe_paint_id(p_value text)
      returns %1$s
      language sql
      immutable
      as $fn$
        select nullif(trim(p_value), '')::%1$s
      $fn$
    $sql$, v_paint_id_type);
  end if;

  if v_writeoffs_paint_id_type <> v_paint_id_type then
    for v_writeoffs_paint_id_type in
      select conname
        from pg_constraint
       where conrelid = 'public.paints_writeoffs'::regclass
         and pg_get_constraintdef(oid) like '%paint_id%'
    loop
      execute format(
        'alter table public.paints_writeoffs drop constraint if exists %I',
        v_writeoffs_paint_id_type
      );
    end loop;

    execute format(
      'alter table public.paints_writeoffs add column if not exists paint_id_migrated %s',
      v_paint_id_type
    );
    execute 'alter table public.paints_writeoffs add column if not exists paint_id_text_legacy text';

    execute $sql$
      update public.paints_writeoffs w
         set paint_id_migrated = public.safe_paint_id(w.paint_id::text)
       where w.paint_id is not null
         and public.safe_paint_id(w.paint_id::text) is not null
         and exists (
           select 1
             from public.paints p
            where p.id = public.safe_paint_id(w.paint_id::text)
         )
    $sql$;

    execute $sql$
      update public.paints_writeoffs w
         set paint_id_text_legacy = nullif(trim(w.paint_id::text), '')
       where w.paint_id is not null
         and (
           public.safe_paint_id(w.paint_id::text) is null
           or not exists (
             select 1
               from public.paints p
              where p.id = public.safe_paint_id(w.paint_id::text)
           )
         )
    $sql$;

    execute $sql$
      select count(*)
        from public.paints_writeoffs w
       where w.paint_id is not null
         and (
           public.safe_paint_id(w.paint_id::text) is null
           or not exists (
             select 1
               from public.paints p
              where p.id = public.safe_paint_id(w.paint_id::text)
           )
         )
    $sql$ into v_invalid_count;
    if v_invalid_count > 0 then
      raise warning 'paints_writeoffs.paint_id contains % legacy value(s) that cannot be cast to %. They were preserved in paint_id_text_legacy and migrated to null paint_id.',
        v_invalid_count, v_paint_id_type;
    end if;

    drop index if exists public.paints_writeoffs_paint_id_idx;

    alter table public.paints_writeoffs rename column paint_id to paint_id_raw_before_type_alignment;
    alter table public.paints_writeoffs rename column paint_id_migrated to paint_id;

    alter table public.paints_writeoffs
      add constraint paints_writeoffs_paint_id_fkey
      foreign key (paint_id) references public.paints(id);
  end if;

  select format_type(a.atttypid, a.atttypmod)
    into v_writeoffs_paint_id_type
    from pg_attribute a
    join pg_class c on c.oid = a.attrelid
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public'
     and c.relname = 'paints_writeoffs'
     and a.attname = 'paint_id'
     and a.attnum > 0
     and not a.attisdropped;

  if v_writeoffs_paint_id_type <> v_paint_id_type then
    raise exception 'public.paints_writeoffs.paint_id type (%) does not match public.paints.id type (%)',
      v_writeoffs_paint_id_type, v_paint_id_type;
  end if;

  for v_writeoffs_paint_id_type in
    select table_name || '.paint_id has type ' || column_type
      from (
        select c.relname as table_name, format_type(a.atttypid, a.atttypmod) as column_type
          from pg_attribute a
          join pg_class c on c.oid = a.attrelid
          join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public'
           and c.relname in (
             'order_paint_reservations',
             'order_paint_pending_writeoffs',
             'paints_writeoffs'
           )
           and a.attname = 'paint_id'
           and a.attnum > 0
           and not a.attisdropped
      ) typed_paint_ids
     where column_type <> v_paint_id_type
  loop
    raise exception 'public.% does not match public.paints.id type %',
      v_writeoffs_paint_id_type, v_paint_id_type;
  end loop;
end $$;

create index if not exists paints_writeoffs_paint_id_idx
  on public.paints_writeoffs(paint_id)
  where paint_id is not null;
