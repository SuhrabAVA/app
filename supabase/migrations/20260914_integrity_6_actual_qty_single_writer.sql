-- ============================================================================
-- Целостность данных, шаг 6: факт заказа считает только сервер (2026-09-14)
--
-- Что чинит
-- ---------
-- orders.actual_qty писали трое, и каждый по своему правилу:
--   1. advance_order_after_task_completion — сумма записей количества того
--      этапа, что закрылся ПОСЛЕДНИМ, и только когда закрыт весь заказ;
--   2. клиент (TaskProvider.recomputeOrderActualQty) — правило «после
--      упаковки» с переводом упаковок в штуки по фасовке;
--   3. клиент при сохранении заказа и отгрузке — toMap() со своим снимком
--      actual_qty, в том числе устаревшим.
-- Итог зависел от того, кто записал последним. Заказ Agosto: упаковка сделала
-- 3100 шт, клиент записал 3100, потом последним закрылся этап ручек без
-- количества — и сервер затёр факт нулём.
--
-- Что делает миграция
-- -------------------
-- 1. order_actual_qty_compute — правило клиента, перенесённое один в один
--    (сверено на проде: 145 из 147 заказов совпали, два расхождения — ошибки
--    данных, а не переноса). null — «не трогать».
-- 2. recompute_order_actual_qty — единственный писатель: считает и записывает.
--    Клиент вызывает её вместо своего расчёта.
-- 3. advance_order_after_task_completion зовёт её после каждого завершения
--    этапа вместо прежнего расчёта «последнего этапа».
-- 4. Триггер на orders не даёт изменить actual_qty никому, кроме неё. Старые
--    версии приложения на планшетах продолжат слать actual_qty при сохранении
--    заказа — значение просто останется прежним.
--
-- Историю не пересчитывает: изменения затронут отгрузки уже закрытых заказов,
-- решение по ним принимается отдельно (data_health_report покажет расхождения).
-- ============================================================================

begin;

-- ─── 1. Правило расчёта ─────────────────────────────────────────────────────

-- stage_sequence_utils.dart: isPackagingStage.
create or replace function public.stage_is_packaging(
  p_stage_id text, p_stage_name text, p_group_key text)
returns boolean
language sql
immutable
as $function$
  with n as (
    select regexp_replace(replace(lower(trim(coalesce(p_stage_name, ''))), '-', '_'), '\s+', '_', 'g') as name_key,
           regexp_replace(replace(lower(trim(coalesce(p_group_key, ''))), '-', '_'), '\s+', '_', 'g') as group_key
  )
  select trim(coalesce(p_stage_id, '')) = 'edeb85db-c7a3-4a24-8f33-70ccdd4aaae1'  -- wpPackagingUuid
      or (n.name_key <> '' and (n.name_key in ('упаковка', 'packaging', 'package')
                                or n.name_key like '%упаков%' or n.name_key like '%packaging%'))
      or n.group_key in ('pack', 'packing', 'packaging', 'package', 'packaging_stage', 'package_stage',
                         'packaging_group', 'package_group', 'pack_stage', 'упаковка')
      or n.group_key like '%упаков%'
    from n;
$function$;

-- stage_quantity_records.dart: countsTowardOrderQuantity + helperIdsFromComments;
-- task_provider.dart: _quantityForActualQty (перевод легаси-упаковок в штуки).
create or replace function public.task_order_quantity_measure(
  p_comments jsonb, p_assignees text[], p_stage_unit text, p_pack_size double precision)
returns table(qty double precision, latest_ms bigint)
language sql
immutable
as $function$
  with c as (
    select e,
           public.task_quantity_payload(e->>'text') as payload,
           trim(coalesce(e->>'userId', e->>'user_id', '')) as author
      from jsonb_array_elements(public.task_comments_to_array(p_comments)) e
  ),
  owner as (
    select coalesce((select trim(a) from unnest(p_assignees) with ordinality u(a, ord)
                      where trim(coalesce(a, '')) <> '' order by ord limit 1), '') as id
  ),
  helpers as (
    select distinct c.author
      from c, owner
     where c.e->>'type' = 'joined' and owner.id <> '' and c.author <> '' and c.author <> owner.id
  ),
  counted as (
    select c.e,
           public.task_quantity_value(c.e->>'text') as v,
           coalesce(nullif(trim(c.payload->>'unit'), ''), coalesce(p_stage_unit, '')) as unit
      from c
     where c.e->>'type' in ('quantity_stage_total', 'quantity_share', 'quantity_done', 'quantity_team_total')
       and not coalesce(c.payload->'generated' = 'true'::jsonb, false)
       and not exists (select 1 from helpers h where h.author = c.author)
  )
  select coalesce(sum(case when regexp_replace(lower(trim(unit)), '\s+', ' ', 'g')
                                in ('уп', 'уп.', 'упак', 'упаковка', 'упаковки', 'пач', 'пачка', 'пачки', 'pack', 'packs')
                           then v * coalesce(p_pack_size, 1) else v end), 0),
         coalesce(max(public.task_comment_millis(e->>'timestamp')), 0)
    from counted;
$function$;

-- quantity_status_service.dart: packSizeFromParams («Упаковка: N»).
create or replace function public.order_pack_size(p_order_id text)
returns double precision
language sql
stable
as $function$
  select coalesce((
           select replace(mm.arr[1], ',', '.')::double precision
             from unnest(o.additional_params) with ordinality as p(val, ord)
             cross join lateral (
               select regexp_match(substr(trim(p.val), char_length('упаковка:') + 1),
                                   '\d+(?:[.,]\d+)?') as arr
             ) mm
            where lower(trim(p.val)) like 'упаковка:%'
              and mm.arr is not null
              and replace(mm.arr[1], ',', '.')::double precision > 0
            order by p.ord
            limit 1), 1)
    from public.orders o
   where o.id::text = p_order_id;
$function$;

-- Задачи заказа с измеренным количеством и моментом завершения
-- (task_provider.dart: _taskCompletionMillis).
create or replace function public.order_actual_qty_rows(p_order_id text)
returns table(stage_id text, grp text, status text, is_pack boolean,
              completion_ms bigint, qty double precision, latest_ms bigint)
language sql
stable
as $function$
  select t.stage_id,
         coalesce(nullif(trim(coalesce(t.stage_group_key, '')), ''), t.stage_id),
         t.status,
         public.stage_is_packaging(t.stage_id, w.name, t.stage_group_key),
         coalesce(
           nullif(greatest(coalesce(t.completed_at, 0), 0), 0),
           nullif((select max(public.task_comment_millis(e->>'timestamp'))
                     from jsonb_array_elements(public.task_comments_to_array(t.comments)) e
                    where e->>'type' in ('user_done', 'quantity_done', 'quantity_team_total', 'finish_note')), 0),
           floor(extract(epoch from t.updated_at) * 1000)::bigint,
           0),
         q.qty,
         q.latest_ms
    from public.tasks t
    left join public.workplaces w on w.id::text = t.stage_id
    cross join lateral public.task_order_quantity_measure(
      t.comments, t.assignees, w.unit, public.order_pack_size(p_order_id)) q
   where t.order_id::text = p_order_id;
$function$;

-- task_provider.dart: _isLastStage (production.plans на проде пуст — клиент
-- обращается к нему как к несуществующей таблице и падает в prod_plans).
create or replace function public.order_stage_is_last(p_order_id text, p_stage_id text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_plan_ids uuid[];
  v_max int;
begin
  select array_agg(id) into v_plan_ids from prod_plans where order_id::text = p_order_id;
  if coalesce(array_length(v_plan_ids, 1), 0) = 1
     and exists (select 1 from prod_plan_stages s where s.plan_id = v_plan_ids[1]) then
    select greatest(coalesce(max(coalesce(s.step_no, s.seq, 0)), 0), 0) into v_max
      from prod_plan_stages s where s.plan_id = v_plan_ids[1];
    return exists (
      select 1 from prod_plan_stages s
       where s.plan_id = v_plan_ids[1]
         and coalesce(s.step_no, s.seq, 0) = v_max
         and coalesce(nullif(s.stage_id, ''), s.id::text) = p_stage_id);
  end if;
  return not exists (
    select 1 from tasks t
     where t.order_id::text = p_order_id
       and coalesce(t.stage_id, '') not in ('', p_stage_id)
       and lower(coalesce(t.status, '')) <> 'completed');
end
$function$;

-- task_provider.dart: recomputeOrderActualQty. null — не трогать значение.
create or replace function public.order_actual_qty_compute(
  p_order_id text, p_completed_stage_id text default null)
returns double precision
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v_has_packaging boolean;
  v_packaging_done boolean;
  v_packaging_ms bigint;
  v_result double precision;
  v_stage text := nullif(trim(coalesce(p_completed_stage_id, '')), '');
begin
  if coalesce(trim(p_order_id), '') = '' then return null; end if;
  if not exists (select 1 from orders o where o.id::text = p_order_id) then return null; end if;

  select count(*) > 0, coalesce(bool_and(r.status = 'completed'), false), max(r.completion_ms)
    into v_has_packaging, v_packaging_done, v_packaging_ms
    from public.order_actual_qty_rows(p_order_id) r
   where r.is_pack;

  -- Факт — только то, что зафиксировано после завершения упаковки: её
  -- собственные записи и этапы, записавшие количество не раньше её закрытия.
  -- Из них берётся ОДНА группа этапа — записавшая количество последней.
  if v_has_packaging then
    if not v_packaging_done then return null; end if;
    select g.total into v_result
      from (select r.grp, sum(r.qty) as total, max(r.latest_ms) as latest
              from public.order_actual_qty_rows(p_order_id) r
             where r.qty > 0 and (r.is_pack or r.latest_ms >= v_packaging_ms)
             group by r.grp) g
     order by g.latest desc
     limit 1;
    return v_result;
  end if;

  -- Заказ без упаковки (легаси): количество последнего этапа маршрута.
  if v_stage is null then return null; end if;
  if not exists (select 1 from tasks t where t.order_id::text = p_order_id and t.stage_id = v_stage)
     or exists (select 1 from tasks t
                 where t.order_id::text = p_order_id and t.stage_id = v_stage
                   and t.status <> 'completed') then
    return null;
  end if;
  if not public.order_stage_is_last(p_order_id, v_stage) then return null; end if;

  select coalesce(sum(q.qty), 0) into v_result
    from tasks t
    cross join lateral public.task_order_quantity_measure(t.comments, t.assignees, null, 1) q
   where t.order_id::text = p_order_id and t.stage_id = v_stage;
  return v_result;
end
$function$;

-- ─── 2. Единственный писатель ───────────────────────────────────────────────

create or replace function public.recompute_order_actual_qty(
  p_order_id text, p_completed_stage_id text default null)
returns double precision
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_qty double precision := public.order_actual_qty_compute(p_order_id, p_completed_stage_id);
begin
  if v_qty is null then return null; end if;

  perform set_config('app.actual_qty_writer', 'server', true);
  update orders
     set actual_qty = v_qty::numeric
   where id::text = p_order_id
     and actual_qty is distinct from v_qty::numeric;
  perform set_config('app.actual_qty_writer', '', true);

  return v_qty;
end
$function$;

comment on function public.recompute_order_actual_qty(text, text) is
  'Единственный писатель orders.actual_qty. Считает факт по правилу «после '
  'упаковки» (order_actual_qty_compute) и записывает. Возвращает null, если '
  'правило велит значение не трогать (упаковка ещё не завершена).';

create or replace function public.orders_guard_actual_qty()
returns trigger
language plpgsql
as $function$
begin
  if new.actual_qty is distinct from old.actual_qty
     and coalesce(current_setting('app.actual_qty_writer', true), '') <> 'server' then
    new.actual_qty := old.actual_qty;
  end if;
  return new;
end
$function$;

comment on function public.orders_guard_actual_qty() is
  'orders.actual_qty меняет только recompute_order_actual_qty. Остальные '
  'записи (сохранение заказа, отгрузка, старые версии приложения) значение не '
  'меняют. Ручная правка из SQL: select set_config(''app.actual_qty_writer'', '
  '''server'', true) в той же транзакции.';

drop trigger if exists orders_guard_actual_qty on public.orders;
create trigger orders_guard_actual_qty
  before update of actual_qty on public.orders
  for each row
  execute function public.orders_guard_actual_qty();

-- ─── 3. Завершение этапа пересчитывает факт ─────────────────────────────────
--
-- Прежний расчёт «последнего этапа» в advance_order_after_task_completion
-- убирается (его запись всё равно заблокировал бы триггер выше), а в конце
-- функции — после смены статусов этапа и заказа — зовётся единый пересчёт.

do $patch$
declare
  v_sig constant regprocedure :=
    'public.advance_order_after_task_completion(text,text,text,text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_old_update constant text :=
    'update orders\s+set actual_qty = v_actual_qty\s+where id::text = p_order_id;';
  v_tail constant text := 'end;\s*\$function\$\s*$';
  v_count int;
begin
  if position('recompute_order_actual_qty' in v_def) > 0 then
    raise notice 'advance_order_after_task_completion уже пропатчена — пропуск';
    return;
  end if;

  v_count := regexp_count(v_def, v_old_update);
  if v_count <> 1 then
    raise exception 'Запись actual_qty найдена % раз(а) вместо 1 — '
      'функция изменилась, миграцию нужно пересобрать', v_count;
  end if;
  v_count := regexp_count(v_def, v_tail);
  if v_count <> 1 then
    raise exception 'Конец функции найден % раз(а) вместо 1', v_count;
  end if;

  v_def := regexp_replace(v_def, v_old_update,
    'null; -- actual_qty пишет только recompute_order_actual_qty (20260914)');
  v_def := regexp_replace(v_def, v_tail,
    '  -- Факт заказа: единое правило «после упаковки» (20260914).' || chr(10)
    || '  perform public.recompute_order_actual_qty(p_order_id, p_stage_id);' || chr(10)
    || 'end;' || chr(10) || '$function$' || chr(10));
  execute v_def;
end
$patch$;

revoke execute on function public.recompute_order_actual_qty(text, text) from public, anon;
grant execute on function public.recompute_order_actual_qty(text, text) to authenticated, service_role;
revoke execute on function public.order_actual_qty_compute(text, text) from public, anon;
grant execute on function public.order_actual_qty_compute(text, text) to authenticated, service_role;
revoke execute on function public.order_stage_is_last(text, text) from public, anon;
grant execute on function public.order_stage_is_last(text, text) to authenticated, service_role;

commit;
