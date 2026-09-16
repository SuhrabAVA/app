-- ============================================================================
-- Целостность данных, шаг 1: бронь краски под отложенным списанием (2026-09-14)
--
-- Что чинит
-- ---------
-- Флексопечать, закрывая этап, отпускала ВСЕ оставшиеся брони заказа — в том
-- числе краску, которую оператор только что оставил «на потом» (долг в
-- order_paint_pending_writeoffs). Цикл в конце
-- complete_flex_printing_stage_with_paint_queue ставил
-- released_qty = reserved_qty - used_qty и не спрашивал про долг. Фикс
-- 20260911 научил проверке только release_order_paint_reservations, а этот
-- цикл остался прежним. На 14.09: 33 долга, у 29 брони нет — все долги с 07.09.
--
-- Без брони краску под долгом забирает следующий заказ, и списание долга
-- падает с «Недостаточно краски» при полном складе.
--
-- Что делает миграция
-- -------------------
-- 1. order_paint_pending_debt_grams — сколько граммов краски заказ ещё должен.
-- 2. Патч флексопечати: отпускается только то, что сверх долга; строка долга,
--    пришедшая без paint_id, получает его по имени краски (у 6 долгов id пуст,
--    их не находила ни бронь, ни проверка долга).
-- 3. Данные: долгам без id проставляется краска (только при однозначном
--    совпадении имени), бронь под долгом восстанавливается.
--
-- Бронь восстанавливается НЕ БОЛЬШЕ свободного остатка. Иначе у краски
-- «доступно» уйдёт в минус, и флексопечать ДРУГОГО заказа с этой краской
-- встанет на проверке остатка — остановка цеха хуже недобронированного долга.
-- Долги, которым остатка не хватило, показывает data_health_report
-- (шаг 4): там нужна инвентаризация.
-- ============================================================================

begin;

-- ─── 1. Долг заказа по краске ───────────────────────────────────────────────

create or replace function public.order_paint_pending_debt_grams(
  p_order_id text,
  p_paint_id uuid,
  p_paint_name text default null
)
returns double precision
language sql
stable
security definer
set search_path to 'public'
as $function$
  -- Строка долга с paint_id сравнивается только по id: иначе две краски с
  -- одинаковым именем (на складе такие есть) делили бы один долг на двоих.
  select coalesce(sum(coalesce(w.actual_used_amount, w.planned_amount, 0)), 0)
    from public.order_paint_pending_writeoffs w
   where w.order_id = p_order_id
     and w.status = 'pending'
     and (
       (p_paint_id is not null and w.paint_id = p_paint_id)
       or (
         w.paint_id is null
         and coalesce(trim(p_paint_name), '') <> ''
         and public.normalize_paint_name(w.paint_name)
             = public.normalize_paint_name(p_paint_name)
       )
     );
$function$;

comment on function public.order_paint_pending_debt_grams(text, uuid, text) is
  'Граммы краски, которые заказ оставил на отложенное списание и ещё не '
  'списал. Столько брони нельзя отпускать при закрытии флексопечати.';

revoke execute on function public.order_paint_pending_debt_grams(text, uuid, text)
  from public, anon;
grant execute on function public.order_paint_pending_debt_grams(text, uuid, text)
  to authenticated, service_role;

-- ─── 2. Патч флексопечати ───────────────────────────────────────────────────
--
-- Тело (22 КБ) берётся из базы и правится заменой строк: переписывать его
-- руками — значит рисковать откатить чужие правки. Каждый шаблон обязан
-- встретиться ровно один раз, иначе миграция падает целиком.

do $patch$
declare
  v_sig constant regprocedure :=
    'public.complete_flex_printing_stage_with_paint_queue(text,text,text,text,jsonb,jsonb,text,text,text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);

  v_release_old constant text :=
    'set released_qty = greatest(reserved_qty - used_qty, 0),';
  v_release_new constant text :=
    'set released_qty = greatest(reserved_qty - used_qty'
    || ' - public.order_paint_pending_debt_grams(p_order_id, paint_id, paint_name), 0),';

  v_resolve_old constant text :=
    'if v_paint_id is null and coalesce(v_paint_name, '''') = '''' then';
  v_resolve_new constant text :=
    'if v_paint_id is null and coalesce(v_paint_name, '''') <> '''' then '
    || 'select p.id into v_paint_id from paints p '
    || 'where public.normalize_paint_name(p.description) = public.normalize_paint_name(v_paint_name) '
    || 'order by p.id limit 1; '
    || 'end if; '
    || 'if v_paint_id is null and coalesce(v_paint_name, '''') = '''' then';

  v_count int;
begin
  if position(v_release_new in v_def) > 0 then
    raise notice 'Флексопечать уже пропатчена — пропуск';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_release_old, '')))
             / length(v_release_old);
  if v_count <> 1 then
    raise exception 'Шаблон отпуска брони найден % раз(а) вместо 1 — '
      'функция изменилась, миграцию нужно пересобрать', v_count;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_resolve_old, '')))
             / length(v_resolve_old);
  if v_count <> 1 then
    raise exception 'Шаблон строки долга найден % раз(а) вместо 1 — '
      'функция изменилась, миграцию нужно пересобрать', v_count;
  end if;

  v_def := replace(v_def, v_release_old, v_release_new);
  v_def := replace(v_def, v_resolve_old, v_resolve_new);
  execute v_def;
end
$patch$;

-- ─── 3. Данные ──────────────────────────────────────────────────────────────

-- 3.1. Долгам без id — краску по имени. Только однозначное совпадение и
-- только если такой же строки с id ещё нет (иначе упрёмся в уникальный
-- индекс долга).
update public.order_paint_pending_writeoffs w
   set paint_id = m.paint_id,
       updated_at = now()
  from (
    select w2.id, min(p.id::text)::uuid as paint_id
      from public.order_paint_pending_writeoffs w2
      join public.paints p
        on public.normalize_paint_name(p.description)
           = public.normalize_paint_name(w2.paint_name)
     where w2.status = 'pending'
       and w2.paint_id is null
     group by w2.id
    having count(*) = 1
  ) m
 where w.id = m.id
   and not exists (
     select 1
       from public.order_paint_pending_writeoffs d
      where d.status = 'pending'
        and d.order_id = w.order_id
        and coalesce(d.task_id, '') = coalesce(w.task_id, '')
        and coalesce(d.stage_id, '') = coalesce(w.stage_id, '')
        and d.paint_id = m.paint_id
   );

-- 3.2. Бронь под долгом, не больше свободного остатка краски.
do $restore$
declare
  rec record;
  v_res public.order_paint_reservations%rowtype;
  v_active double precision;
  v_need double precision;
  v_stock double precision;
  v_reserved_all double precision;
  v_add double precision;
  v_from_released double precision;
  v_touched uuid[] := '{}';
begin
  for rec in
    select w.order_id,
           w.paint_id,
           max(w.paint_name) as paint_name,
           sum(coalesce(w.actual_used_amount, w.planned_amount, 0)) as debt,
           min(w.created_at) as since
      from public.order_paint_pending_writeoffs w
     where w.status = 'pending'
       and w.paint_id is not null
       -- удалённый заказ бронь держать не должен
       and exists (select 1 from public.orders o where o.id::text = w.order_id)
     group by w.order_id, w.paint_id
     order by min(w.created_at)
  loop
    select * into v_res
      from public.order_paint_reservations r
     where r.order_id = rec.order_id
       and (r.paint_id = rec.paint_id
            or (r.paint_id is null
                and public.normalize_paint_name(r.paint_name)
                    = public.normalize_paint_name(rec.paint_name)))
     order by (r.paint_id is not null) desc
     limit 1
     for update;

    v_active := case when v_res.id is null then 0
                     else greatest(v_res.reserved_qty - v_res.used_qty - v_res.released_qty, 0)
                end;
    v_need := rec.debt - v_active;
    continue when v_need <= 0;

    select p.quantity into v_stock
      from public.paints p where p.id = rec.paint_id for update;
    select coalesce(sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0)), 0)
      into v_reserved_all
      from public.order_paint_reservations r
     where r.paint_id = rec.paint_id;

    v_add := least(v_need, greatest(coalesce(v_stock, 0) - v_reserved_all, 0));
    continue when v_add <= 0;

    if v_res.id is null then
      insert into public.order_paint_reservations(
        order_id, paint_id, paint_name, reserved_qty, used_qty, released_qty)
      values (rec.order_id, rec.paint_id, rec.paint_name, v_add, 0, 0)
      -- у заказа может уже быть строка с тем же именем, но другой краской
      -- (дубли имён на складе) — её не трогаем, долг покажет отчёт
      on conflict do nothing;
    else
      v_from_released := least(v_add, v_res.released_qty);
      update public.order_paint_reservations
         set released_qty = released_qty - v_from_released,
             reserved_qty = reserved_qty + (v_add - v_from_released),
             paint_id = coalesce(paint_id, rec.paint_id),
             updated_at = now()
       where id = v_res.id;
    end if;

    v_touched := array_append(v_touched, rec.paint_id);
  end loop;

  perform public.recalculate_paint_reserved_qty(v_touched);
end
$restore$;

commit;
