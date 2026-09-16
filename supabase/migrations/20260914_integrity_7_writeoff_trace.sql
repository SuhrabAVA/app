-- ============================================================================
-- Целостность данных, шаг 7: списание склада знает заказ, сотрудника и
-- источник (2026-09-14)
--
-- Что чинит
-- ---------
-- В papers_writeoffs / paints_writeoffs не было колонки заказа. Заказ жил
-- ТЕКСТОМ причины, и даже этот текст терялся:
--   * флексопечать писала «…по заказу <uuid>», а BEFORE-триггер
--     apply_customer_to_flex_paint_writeoff_reason заменял uuid на имя
--     заказчика (для читаемости журнала);
--   * списание бумаги сразу писало имя заказчика.
-- У 54 заказчиков больше одного заказа, поэтому 305 списаний краски и 177
-- бумаги нельзя было однозначно связать с заказом. «Кто списал» лежал в
-- by_name вперемешку: id сотрудника, ФИО, «system».
--
-- Что делает миграция
-- -------------------
-- 1. Колонки order_id (ссылка на заказ), employee_id (ссылка на сотрудника) и
--    source (откуда списание: manual, paper_stage, paper_order_completed,
--    paper_shipment, flex_now, flex_queue).
-- 2. BEFORE INSERT триггер aa_writeoffs_fill_trace заполняет их, если
--    вызывающий не передал: заказ — из uuid в причине (срабатывает РАНЬШЕ
--    замены uuid на имя: триггеры одного момента идут по алфавиту),
--    сотрудник — по id или однозначному ФИО в by_name, источник — по шаблону
--    причины.
-- 3. finalize_order_paper_reservations пишет заказ и источник явно.
-- 4. История: заказ проставляется там, где он восстанавливается однозначно
--    (момент транзакции списания совпадает с отметкой заказа или события;
--    либо имя заказчика единственно). Остальное остаётся пустым — угадывать
--    нельзя.
-- ============================================================================

begin;

-- ─── 1. Колонки ─────────────────────────────────────────────────────────────

alter table public.papers_writeoffs
  add column if not exists order_id uuid references public.orders(id) on delete set null,
  add column if not exists employee_id text references public.employees(id) on delete set null,
  add column if not exists source text;

alter table public.paints_writeoffs
  add column if not exists order_id uuid references public.orders(id) on delete set null,
  add column if not exists employee_id text references public.employees(id) on delete set null,
  add column if not exists source text;

alter table public.papers_writeoffs drop constraint if exists papers_writeoffs_source_check;
alter table public.papers_writeoffs add constraint papers_writeoffs_source_check
  check (source is null or source in ('manual', 'paper_stage', 'paper_order_completed', 'paper_shipment', 'paper_order'));

alter table public.paints_writeoffs drop constraint if exists paints_writeoffs_source_check;
alter table public.paints_writeoffs add constraint paints_writeoffs_source_check
  check (source is null or source in ('manual', 'flex_now', 'flex_queue'));

create index if not exists papers_writeoffs_order_id_idx on public.papers_writeoffs(order_id);
create index if not exists paints_writeoffs_order_id_idx on public.paints_writeoffs(order_id);
create index if not exists papers_writeoffs_employee_id_idx on public.papers_writeoffs(employee_id);
create index if not exists paints_writeoffs_employee_id_idx on public.paints_writeoffs(employee_id);

comment on column public.papers_writeoffs.order_id is 'Заказ, по которому списана бумага (null — ручное списание склада).';
comment on column public.paints_writeoffs.order_id is 'Заказ, чья краска списана. Для flex_queue — заказ, оставивший краску на отложенное списание.';
comment on column public.papers_writeoffs.source is 'manual | paper_stage | paper_order_completed | paper_shipment | paper_order (история: заказ не восстановлен)';
comment on column public.paints_writeoffs.source is 'manual | flex_now | flex_queue';

-- ─── 2. Сотрудник по by_name ────────────────────────────────────────────────

create or replace function public.employee_id_from_actor(p_actor text)
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- by_name бывает id сотрудника, ФИО («Иванов Иван Иванович», иногда с
  -- хвостом «Склад» или «.») или «system». ФИО принимается только
  -- однозначное: однофамильцев лучше оставить без привязки, чем привязать
  -- не к тому.
  with a as (
    select trim(coalesce(p_actor, '')) as raw,
           trim(regexp_replace(regexp_replace(lower(coalesce(p_actor, '')),
                '[^[:alpha:][:space:]]', ' ', 'g'), '\s+', ' ', 'g')) as norm
  ),
  by_id as (
    select e.id from employees e, a where e.id = a.raw
  ),
  by_name as (
    select e.id
      from employees e, a
     where a.norm <> ''
       and trim(regexp_replace(regexp_replace(lower(concat_ws(' ', e.last_name, e.first_name, e.patronymic)),
                '[^[:alpha:][:space:]]', ' ', 'g'), '\s+', ' ', 'g')) = a.norm
  )
  select coalesce(
    (select id from by_id limit 1),
    (select min(id) from by_name having count(*) = 1)
  );
$function$;

revoke execute on function public.employee_id_from_actor(text) from public, anon;
grant execute on function public.employee_id_from_actor(text) to authenticated, service_role;

-- ─── 3. Триггер заполнения ──────────────────────────────────────────────────

create or replace function public.writeoffs_fill_trace()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uuid text;
begin
  if new.order_id is null and new.reason is not null then
    v_uuid := substring(new.reason from '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
    if v_uuid is not null and exists (select 1 from orders o where o.id::text = lower(v_uuid)) then
      new.order_id := lower(v_uuid)::uuid;
    end if;
  end if;

  if new.source is null then
    new.source := case
      when tg_table_name = 'paints_writeoffs' and new.reason like 'Списание флексопечати по заказу %из очереди' then 'flex_queue'
      when tg_table_name = 'paints_writeoffs' and new.reason like 'Списание флексопечати по заказу %' then 'flex_now'
      when tg_table_name = 'papers_writeoffs' and new.reason like 'Списание бумаги по заказу %' then 'paper_order'
      else 'manual'
    end;
  end if;

  if new.employee_id is null then
    new.employee_id := public.employee_id_from_actor(new.by_name);
  end if;

  return new;
end
$function$;

comment on function public.writeoffs_fill_trace() is
  'Заполняет order_id, source и employee_id списания, если их не передали. '
  'Имя триггера начинается с aa_, чтобы он шёл РАНЬШЕ '
  'apply_customer_to_flex_paint_writeoff_reason, которая заменяет uuid заказа '
  'в причине на имя заказчика.';

drop trigger if exists aa_writeoffs_fill_trace on public.papers_writeoffs;
create trigger aa_writeoffs_fill_trace
  before insert on public.papers_writeoffs
  for each row execute function public.writeoffs_fill_trace();

drop trigger if exists aa_writeoffs_fill_trace on public.paints_writeoffs;
create trigger aa_writeoffs_fill_trace
  before insert on public.paints_writeoffs
  for each row execute function public.writeoffs_fill_trace();

-- ─── 4. Списание бумаги по заказу ───────────────────────────────────────────

create or replace function public.finalize_order_paper_reservations(p_order_id text, p_actor text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  rec record;
  v_order_id order_paper_reservations.order_id%type;
  v_already timestamptz;
  v_label text;
  v_reason text;
  v_shipped timestamptz;
  v_source text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  v_order_id := p_order_id;

  select o.paper_written_off_at, nullif(btrim(o.customer), ''), o.shipped_at
    into v_already, v_label, v_shipped
    from public.orders o
   where o.id::text = p_order_id;

  -- Уже списывали. Бронь, которую мог заново создать клиент при правке заказа,
  -- просто снимаем: метры давно ушли со склада, держать их незачем.
  if v_already is not null then
    delete from public.order_paper_reservations where order_id = v_order_id;
    return;
  end if;

  v_reason := format('Списание бумаги по заказу %s', coalesce(v_label, p_order_id));

  -- Откуда списание: на этапе маршрута (в заказе ещё есть незакрытые этапы),
  -- при отгрузке или при закрытии заказа.
  v_source := case
    when exists (select 1 from public.tasks t
                  where t.order_id::text = p_order_id and t.status <> 'completed')
      then 'paper_stage'
    when v_shipped is not null then 'paper_shipment'
    else 'paper_order_completed'
  end;

  for rec in
    select r.paper_id, r.qty
    from public.order_paper_reservations r
    where r.order_id = v_order_id
    for update
  loop
    if rec.qty <= 0 then
      continue;
    end if;

    insert into public.papers_writeoffs(paper_id, qty, reason, by_name, order_id, source)
    values (
      rec.paper_id,
      rec.qty,
      v_reason,
      coalesce(nullif(trim(p_actor), ''), 'system'),
      v_order_id,
      v_source
    );
  end loop;

  update public.orders
     set paper_written_off_at = now()
   where id::text = p_order_id;

  delete from public.order_paper_reservations where order_id = v_order_id;
end;
$function$;

-- ─── 5. История ─────────────────────────────────────────────────────────────

-- 5.1. Сотрудник — у всех строк, где он определяется.
update public.papers_writeoffs w
   set employee_id = public.employee_id_from_actor(w.by_name)
 where w.employee_id is null
   and public.employee_id_from_actor(w.by_name) is not null;

update public.paints_writeoffs w
   set employee_id = public.employee_id_from_actor(w.by_name)
 where w.employee_id is null
   and public.employee_id_from_actor(w.by_name) is not null;

-- 5.2. Бумага: транзакция списания ставит orders.paper_written_off_at тем же
-- now(), что и created_at строк списания.
with cand as (
  select w.id,
         coalesce(
           (select min(o.id::text) from orders o
             where o.paper_written_off_at = w.created_at
            having count(*) = 1),
           (select min(o.id::text) from orders o
             where lower(trim(o.customer)) = lower(trim(substring(w.reason from 'Списание бумаги по заказу (.*)$')))
            having count(*) = 1)
         ) as order_id
    from public.papers_writeoffs w
   where w.order_id is null
     and w.reason like 'Списание бумаги по заказу %'
)
update public.papers_writeoffs w
   set order_id = cand.order_id::uuid
  from cand
 where w.id = cand.id and cand.order_id is not null;

update public.papers_writeoffs w
   set source = case
     when coalesce(w.reason, '') not like 'Списание бумаги по заказу %' then 'manual'
     when w.order_id is null then 'paper_order'
     when exists (select 1 from tasks t
                   where t.order_id = w.order_id
                     and coalesce(t.completed_at, 0) > floor(extract(epoch from w.created_at) * 1000) + 1000)
       then 'paper_stage'
     when exists (select 1 from orders o
                   where o.id = w.order_id and o.shipped_at is not null
                     and o.shipped_at <= w.created_at + interval '1 second')
       then 'paper_shipment'
     else 'paper_order_completed'
   end
 where w.source is null;

-- 5.3. Краска «списать сейчас»: событие flex_printing_completed пишется в той
-- же транзакции; запасной путь — заказчик с флексопечатью, закрытой в пределах
-- 10 минут от списания; последний — единственный заказ с таким именем.
with w as (
  select w.id, w.created_at,
         trim(substring(w.reason from 'Списание флексопечати по заказу (.*)$')) as label
    from public.paints_writeoffs w
   where w.order_id is null
     and w.reason like 'Списание флексопечати по заказу %'
     and w.reason not like '%из очереди'
),
cand as (
  select w.id,
         coalesce(
           (select min(e.order_id) from order_events e
             where e.event_type = 'flex_printing_completed' and e.created_at = w.created_at
            having count(distinct e.order_id) = 1),
           (select min(o.id::text) from orders o
             where (o.id::text = w.label or lower(trim(o.customer)) = lower(w.label))
               and exists (select 1 from tasks t
                            where t.order_id = o.id
                              and t.stage_id = '0571c01c-f086-47e4-81b2-5d8b2ab91218'  -- wpFlexPrintingUuid
                              and t.completed_at is not null
                              and abs(t.completed_at - floor(extract(epoch from w.created_at) * 1000)) < 600000)
            having count(*) = 1),
           (select min(o.id::text) from orders o
             where o.id::text = w.label or lower(trim(o.customer)) = lower(w.label)
            having count(*) = 1)
         ) as order_id
    from w
)
update public.paints_writeoffs p
   set order_id = cand.order_id::uuid
  from cand
 where p.id = cand.id
   and cand.order_id is not null
   and exists (select 1 from orders o where o.id::text = cand.order_id);

-- 5.4. Краска из очереди: строка долга получает written_off_at той же
-- транзакцией; запасной путь — единственный заказ с таким именем.
with w as (
  select w.id, w.created_at, w.paint_id,
         trim(regexp_replace(substring(w.reason from 'Списание флексопечати по заказу (.*)$'), ' из очереди$', '')) as label
    from public.paints_writeoffs w
   where w.order_id is null
     and w.reason like 'Списание флексопечати по заказу %из очереди'
),
cand as (
  select w.id,
         coalesce(
           (select min(p.order_id) from order_paint_pending_writeoffs p
             where p.status = 'written_off'
               and p.paint_id = w.paint_id
               and abs(extract(epoch from p.written_off_at - w.created_at)) < 2
            having count(distinct p.order_id) = 1),
           (select min(o.id::text) from orders o
             where o.id::text = w.label or lower(trim(o.customer)) = lower(w.label)
            having count(*) = 1)
         ) as order_id
    from w
)
update public.paints_writeoffs p
   set order_id = cand.order_id::uuid
  from cand
 where p.id = cand.id
   and cand.order_id is not null
   and exists (select 1 from orders o where o.id::text = cand.order_id);

update public.paints_writeoffs w
   set source = case
     when w.reason like 'Списание флексопечати по заказу %из очереди' then 'flex_queue'
     when w.reason like 'Списание флексопечати по заказу %' then 'flex_now'
     else 'manual'
   end
 where w.source is null;

-- ─── 6. Проверки в отчёте о здоровье данных ─────────────────────────────────
--
-- История, где заказ не восстановился, в отчёт не идёт — она известна и
-- неисправима. Проверяются только списания после этой миграции: у них заказ
-- и сотрудник обязаны быть.

do $patch$
declare
  v_sig constant regprocedure := 'public.data_health_report()'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_anchor constant text := 'union all\s+select ''orphan_paint_rows''';
  v_since constant text := quote_literal(now()::text);
  v_checks text;
  v_count int;
begin
  if position('auto_writeoff_without_order' in v_def) > 0 then
    raise notice 'data_health_report уже содержит проверки списаний — пропуск';
    return;
  end if;

  v_count := regexp_count(v_def, v_anchor);
  if v_count <> 1 then
    raise exception 'Шаблон orphan_paint_rows найден % раз(а) вместо 1', v_count;
  end if;

  v_checks :=
    'union all' || chr(10)
    || '  select ''auto_writeoff_without_order'', ''critical'', ''Автосписание склада без заказа'', count(*),' || chr(10)
    || '         ''Списание по заказу записано без order_id. Проверить триггер aa_writeoffs_fill_trace и вызывающую функцию.'',' || chr(10)
    || '         (select jsonb_agg(x) from (select jsonb_build_object(''таблица'', t, ''причина'', reason, ''когда'', created_at) x from (' || chr(10)
    || '            select ''papers'' t, reason, created_at from papers_writeoffs where source like ''paper%'' and order_id is null and created_at >= ' || v_since || '::timestamptz' || chr(10)
    || '            union all select ''paints'', reason, created_at from paints_writeoffs where source in (''flex_now'', ''flex_queue'') and order_id is null and created_at >= ' || v_since || '::timestamptz) a limit 10) s)' || chr(10)
    || '    from (select 1 from papers_writeoffs where source like ''paper%'' and order_id is null and created_at >= ' || v_since || '::timestamptz' || chr(10)
    || '          union all select 1 from paints_writeoffs where source in (''flex_now'', ''flex_queue'') and order_id is null and created_at >= ' || v_since || '::timestamptz) x' || chr(10)
    || '  union all' || chr(10)
    || '  select ''writeoff_without_employee'', ''info'', ''Списание склада без привязки к сотруднику'', count(*),' || chr(10)
    || '         ''В by_name не id и не однозначное ФИО сотрудника — кто списал, по базе не установить.'',' || chr(10)
    || '         (select jsonb_agg(distinct by_name) from (select by_name from papers_writeoffs where employee_id is null and coalesce(by_name, '''') not in ('''', ''system'') and created_at >= ' || v_since || '::timestamptz' || chr(10)
    || '            union all select by_name from paints_writeoffs where employee_id is null and coalesce(by_name, '''') not in ('''', ''system'') and created_at >= ' || v_since || '::timestamptz) s)' || chr(10)
    || '    from (select 1 from papers_writeoffs where employee_id is null and coalesce(by_name, '''') not in ('''', ''system'') and created_at >= ' || v_since || '::timestamptz' || chr(10)
    || '          union all select 1 from paints_writeoffs where employee_id is null and coalesce(by_name, '''') not in ('''', ''system'') and created_at >= ' || v_since || '::timestamptz) y' || chr(10)
    || '  union all' || chr(10)
    || '  select ''orphan_paint_rows''';

  v_def := regexp_replace(v_def, v_anchor, v_checks);
  execute v_def;
end
$patch$;

commit;
