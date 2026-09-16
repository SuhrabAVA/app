-- ============================================================================
-- Целостность данных, шаг 9: действия склада бумаги и краски — функциями
-- журнала (2026-09-14)
--
-- ПРИМЕНЯТЬ ПОСЛЕ шага 8.
--
-- Приложение раньше само читало остаток, прибавляло/вычитало и записывало
-- число обратно (возврат, отмена списания и прихода, правка остатка). Между
-- чтением и записью остаток мог измениться на другом устройстве, а в журнале
-- действие не оставляло следа. Теперь каждое действие — одна функция, одна
-- транзакция, одна запись журнала:
--
--   stock_set_quantity     — пересчёт на складе или правка остатка;
--   stock_register_return  — возврат на склад (приход с источником return);
--   stock_cancel_movement  — отмена прихода, списания или инвентаризации.
--
-- Плюс отчёт о здоровье данных сверяет остаток с журналом без отменённых
-- записей, и удаляется старая complete_flex_printing_stage: она списывала
-- краску дважды (вставка в журнал + явный update), клиент её не вызывает.
-- ============================================================================

begin;

-- ─── 1. Пересчёт и правка остатка ───────────────────────────────────────────

create or replace function public.stock_set_quantity(
  p_type text,
  p_item uuid,
  p_qty numeric,
  p_kind text default 'count',
  p_note text default null,
  p_actor text default null
)
returns numeric
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_stock numeric;
begin
  if p_type not in ('paper', 'paint') then
    raise exception using message = format('Неизвестный тип склада: %s', p_type), errcode = '22023';
  end if;
  if p_kind not in ('count', 'correction') then
    raise exception using message = format('Неизвестный вид записи: %s', p_kind), errcode = '22023';
  end if;
  if p_qty is null or p_qty < 0 then
    raise exception using message = 'Остаток не может быть отрицательным.', errcode = '22023';
  end if;

  if p_type = 'paper' then
    select quantity into v_stock from papers where id = p_item for update;
  else
    select quantity into v_stock from paints where id = p_item for update;
  end if;
  if not found then
    raise exception using message = 'Позиция склада не найдена.', errcode = 'P0002';
  end if;

  -- Правка на то же число — не событие. Пересчёт на складе — событие всегда:
  -- «пересчитали, сошлось» тоже факт.
  if p_kind = 'correction' and v_stock = p_qty then
    return v_stock;
  end if;

  if p_type = 'paper' then
    insert into papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (p_item, p_qty, v_stock, p_kind, nullif(trim(coalesce(p_note, '')), ''), p_actor, auth.uid());
  else
    insert into paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (p_item, p_qty, v_stock, p_kind, nullif(trim(coalesce(p_note, '')), ''), p_actor, auth.uid());
  end if;

  return p_qty;
end
$function$;

comment on function public.stock_set_quantity(text, uuid, numeric, text, text, text) is
  'Пересчёт (count) или правка (correction) остатка бумаги/краски — записью '
  'журнала инвентаризаций с остатком до неё.';

-- ─── 2. Возврат ─────────────────────────────────────────────────────────────

create or replace function public.stock_register_return(
  p_type text,
  p_item uuid,
  p_qty numeric,
  p_note text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if p_type not in ('paper', 'paint') then
    raise exception using message = format('Неизвестный тип склада: %s', p_type), errcode = '22023';
  end if;
  if p_qty is null or p_qty <= 0 then
    raise exception using message = 'Количество возврата должно быть больше нуля.', errcode = '22023';
  end if;

  if p_type = 'paper' then
    insert into papers_arrivals(paper_id, qty, note, by_name, created_by, source)
    values (p_item, p_qty, coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Возврат'), p_actor, auth.uid(), 'return');
  else
    insert into paints_arrivals(paint_id, qty, note, by_name, created_by, source)
    values (p_item, p_qty, coalesce(nullif(trim(coalesce(p_note, '')), ''), 'Возврат'), p_actor, auth.uid(), 'return');
  end if;
end
$function$;

-- ─── 3. Отмена движения ─────────────────────────────────────────────────────

create or replace function public.stock_cancel_movement(
  p_type text,
  p_movement text,
  p_id uuid,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  c_marker constant text := '[ОТМЕНЕНО]';
  v_prev text := coalesce(current_setting('app.stock_writer', true), '');
  v_item uuid;
  v_qty numeric;
  v_source text;
  v_kind text;
  v_prev_qty numeric;
  v_canceled timestamptz;
  v_created timestamptz;
  v_text text;
  v_stock numeric;
  v_new_stock numeric;
begin
  if p_type not in ('paper', 'paint') then
    raise exception using message = format('Неизвестный тип склада: %s', p_type), errcode = '22023';
  end if;
  if p_movement not in ('writeoff', 'arrival', 'inventory') then
    raise exception using message = format('Неизвестное движение: %s', p_movement), errcode = '22023';
  end if;

  -- Запись движения.
  if p_type = 'paper' and p_movement = 'writeoff' then
    select paper_id, qty, source, canceled_at, created_at, reason
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from papers_writeoffs where id = p_id for update;
  elsif p_type = 'paint' and p_movement = 'writeoff' then
    select paint_id, qty, source, canceled_at, created_at, reason
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from paints_writeoffs where id = p_id for update;
  elsif p_type = 'paper' and p_movement = 'arrival' then
    select paper_id, qty, source, canceled_at, created_at, note
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from papers_arrivals where id = p_id for update;
  elsif p_type = 'paint' and p_movement = 'arrival' then
    select paint_id, qty, source, canceled_at, created_at, note
      into v_item, v_qty, v_source, v_canceled, v_created, v_text
      from paints_arrivals where id = p_id for update;
  elsif p_type = 'paper' then
    select paper_id, counted_qty, kind, previous_qty, canceled_at, created_at, note
      into v_item, v_qty, v_kind, v_prev_qty, v_canceled, v_created, v_text
      from papers_inventories where id = p_id for update;
  else
    select paint_id, counted_qty, kind, previous_qty, canceled_at, created_at, note
      into v_item, v_qty, v_kind, v_prev_qty, v_canceled, v_created, v_text
      from paints_inventories where id = p_id for update;
  end if;

  if v_item is null then
    raise exception using message = 'Запись журнала склада не найдена.', errcode = 'P0002';
  end if;

  -- Повтор отмены — не ошибка: запись уже отменена, делать нечего.
  if v_canceled is not null or coalesce(v_text, '') ilike '%' || c_marker || '%' then
    return;
  end if;

  if p_type = 'paper' then
    select quantity into v_stock from papers where id = v_item for update;
  else
    select quantity into v_stock from paints where id = v_item for update;
  end if;

  if p_movement = 'writeoff' then
    if coalesce(v_source, 'manual') <> 'manual' then
      raise exception using
        message = 'Списание по заказу со склада не отменяется: исправьте количество в заказе или проведите инвентаризацию.',
        errcode = 'check_violation';
    end if;
    if (p_type = 'paper' and exists (select 1 from papers_inventories i
                                      where i.paper_id = v_item and i.kind = 'shortage'
                                        and i.created_at = v_created and i.canceled_at is null))
       or (p_type = 'paint' and exists (select 1 from paints_inventories i
                                         where i.paint_id = v_item and i.kind = 'shortage'
                                           and i.created_at = v_created and i.canceled_at is null)) then
      raise exception using
        message = 'Это списание превысило остаток и записано недостачей — отмена исказит остаток. Проведите инвентаризацию.',
        errcode = 'check_violation';
    end if;
    v_new_stock := coalesce(v_stock, 0) + v_qty;

  elsif p_movement = 'arrival' then
    if coalesce(v_stock, 0) < v_qty then
      raise exception using
        message = format('Недостаточно материала для отмены прихода: остаток %s, приход %s.', coalesce(v_stock, 0), v_qty),
        errcode = 'check_violation';
    end if;
    v_new_stock := v_stock - v_qty;

  else
    if v_kind in ('shortage', 'baseline') then
      raise exception using
        message = 'Запись недостачи или сверки не отменяется — проведите новую инвентаризацию.',
        errcode = 'check_violation';
    end if;
    if v_prev_qty is null then
      raise exception using
        message = 'У этой инвентаризации не сохранён остаток до неё — отменить нельзя, проведите новую.',
        errcode = 'check_violation';
    end if;
    v_new_stock := coalesce(v_stock, 0) + (v_prev_qty - v_qty);
    if v_new_stock < 0 then
      raise exception using
        message = format('Отмена даст отрицательный остаток (%s). Проведите новую инвентаризацию.', v_new_stock),
        errcode = 'check_violation';
    end if;
  end if;

  perform set_config('app.stock_writer', 'journal', true);
  if p_type = 'paper' then
    update papers set quantity = v_new_stock, updated_at = now() where id = v_item;
  else
    update paints set quantity = v_new_stock, updated_at = now() where id = v_item;
  end if;
  perform set_config('app.stock_writer', v_prev, true);

  -- Отметка: колонка для базы и маркер в тексте для экранов склада.
  if p_type = 'paper' and p_movement = 'writeoff' then
    update papers_writeoffs set canceled_at = now(), canceled_by = p_actor,
           reason = trim(c_marker || ' ' || coalesce(reason, '')) where id = p_id;
  elsif p_type = 'paint' and p_movement = 'writeoff' then
    update paints_writeoffs set canceled_at = now(), canceled_by = p_actor,
           reason = trim(c_marker || ' ' || coalesce(reason, '')) where id = p_id;
  elsif p_type = 'paper' and p_movement = 'arrival' then
    update papers_arrivals set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  elsif p_type = 'paint' and p_movement = 'arrival' then
    update paints_arrivals set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  elsif p_type = 'paper' then
    update papers_inventories set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  else
    update paints_inventories set canceled_at = now(), canceled_by = p_actor,
           note = trim(c_marker || ' ' || coalesce(note, '')) where id = p_id;
  end if;
end
$function$;

comment on function public.stock_cancel_movement(text, text, uuid, text) is
  'Отмена прихода, ручного списания или инвентаризации бумаги/краски: остаток '
  'возвращается в той же транзакции, запись помечается canceled_at. '
  'Списания по заказам, недостачи и сверки не отменяются.';

revoke execute on function public.stock_set_quantity(text, uuid, numeric, text, text, text) from public, anon;
grant execute on function public.stock_set_quantity(text, uuid, numeric, text, text, text) to authenticated, service_role;
revoke execute on function public.stock_register_return(text, uuid, numeric, text, text) from public, anon;
grant execute on function public.stock_register_return(text, uuid, numeric, text, text) to authenticated, service_role;
revoke execute on function public.stock_cancel_movement(text, text, uuid, text) from public, anon;
grant execute on function public.stock_cancel_movement(text, text, uuid, text) to authenticated, service_role;

-- ─── 4. Отчёт: сверка без отменённых записей ────────────────────────────────

do $patch$
declare
  v_sig constant regprocedure := 'public.data_health_report()'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_moves constant text :=
    '(from (papers|paints)_(arrivals|writeoffs) (a|w)\s+where (a|w)\.(paper|paint)_id = p\.id and )';
  v_inv constant text :=
    '(from (papers|paints)_inventories i\s+where i\.(paper|paint)_id = p\.id)';
  v_count int;
begin
  if position('canceled_at is null' in v_def) > 0 then
    raise notice 'data_health_report уже учитывает отмены — пропуск';
    return;
  end if;

  v_count := regexp_count(v_def, v_moves);
  if v_count <> 4 then
    raise exception 'Подзапросы движений найдены % раз(а) вместо 4', v_count;
  end if;
  v_count := regexp_count(v_def, v_inv);
  if v_count <> 2 then
    raise exception 'Подзапросы инвентаризаций найдены % раз(а) вместо 2', v_count;
  end if;

  v_def := regexp_replace(v_def, v_moves, '\1\4.canceled_at is null and ', 'g');
  v_def := regexp_replace(v_def, v_inv, '\1 and i.canceled_at is null', 'g');
  execute v_def;
end
$patch$;

-- ─── 5. Старая флексопечать с двойным списанием ─────────────────────────────

drop function if exists public.complete_flex_printing_stage(text, text, text, text, jsonb, text, text, text);

commit;
