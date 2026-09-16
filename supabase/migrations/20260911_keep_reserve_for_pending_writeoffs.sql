-- Отложенное списание краски не отпускает бронь.
--
-- ЖИВОЙ СЛУЧАЙ
-- Оператор на флексопечати отмечает «эта краска будет использоваться дальше» —
-- списание переносится на следующий заказ, в `order_paint_pending_writeoffs`
-- появляется долг. Заказ доходит до последнего этапа, и
-- `advance_order_after_task_completion` возвращает его бронь краски на склад
-- (20260901, раздел про release_order_paint_reservations). Бронь исчезает
-- ВМЕСТЕ с той, за которой висит непогашенный долг.
--
-- Дальше краску забирает следующий заказ — она же «свободна». Когда доходит до
-- списания отложенной строки, списывать нечего: «Недостаточно краски.
-- Доступно 8300, требуется 38350» при полном складе. Долг остался без
-- обеспечения.
--
-- ПРАВИЛО
-- Бронь краски живёт, пока по ней есть непогашенный долг ЭТОГО заказа.
-- Уходит она в двух случаях, и оба означают, что долга больше нет:
--   * долг списали — бронь гасится самим списанием, и погашенную строку
--     удаляет триггер drop_settled_paint_reservation (20260908);
--   * долг убрали (строку удалили или перевели из pending) — бронь снимается
--     триггером ниже.
--
-- ИСКЛЮЧЕНИЕ: УДАЛЕНИЕ ЗАКАЗА
-- При `p_reason = 'order_deleted'` брони снимаются ВСЕ, без оглядки на долги.
-- Удаление заказа нельзя запирать ничем: на этом проект уже обжигался —
-- guard переходящих красок однажды сделал часть заказов неудаляемыми
-- (20260909_carryover_guard_launched_orders_only). Долговые строки при
-- удалении заказа уходят вместе с ним, обеспечивать становится нечего.
--
-- ЧЕГО ЭТА МИГРАЦИЯ НЕ ДЕЛАЕТ
-- Не возвращает краску, уже ушедшую в другой заказ: прошлые долги остались без
-- обеспечения, и разбирать их придётся руками. Правило работает с момента
-- применения.

begin;

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Есть ли по краске непогашенный долг этого заказа
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Сопоставление идёт и по paint_id, и по нормализованному имени: у части
-- долговых строк paint_id пуст (краску вписали текстом, карточки на складе
-- нет) — ровно тот случай, ради которого в 20260717 и заведена
-- normalize_paint_name.

create or replace function public.paint_reservation_has_pending_debt(
  p_order_id text,
  p_paint_id uuid,
  p_paint_name text
)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select exists (
    select 1
      from order_paint_pending_writeoffs w
     where w.order_id::text = p_order_id
       and w.status = 'pending'
       and (
         (p_paint_id is not null and w.paint_id = p_paint_id)
         or (
           coalesce(trim(p_paint_name), '') <> ''
           and public.normalize_paint_name(w.paint_name)
               = public.normalize_paint_name(p_paint_name)
         )
       )
  );
$function$;

comment on function public.paint_reservation_has_pending_debt(text, uuid, text) is
  'Висит ли по краске непогашенное отложенное списание этого заказа. '
  'Сопоставление и по id, и по нормализованному имени: у долговых строк '
  'paint_id бывает пуст, когда краску вписали текстом.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Снятие брони пропускает краски с непогашенным долгом
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.release_order_paint_reservations(
  p_order_id text,
  p_reason text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_touched public.paints.id%type[];
  v_force   boolean;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  -- Удаление заказа снимает всё: см. шапку миграции.
  v_force := coalesce(trim(p_reason), '') = 'order_deleted';

  -- Пересчитать нужно только те краски, чьи строки реально уйдут.
  select array_agg(distinct r.paint_id) into v_touched
    from order_paint_reservations r
   where r.order_id::text = p_order_id
     and r.paint_id is not null
     and (
       v_force
       or not public.paint_reservation_has_pending_debt(
            p_order_id, r.paint_id, r.paint_name)
     );

  delete from order_paint_reservations r
   where r.order_id::text = p_order_id
     and (
       v_force
       or not public.paint_reservation_has_pending_debt(
            p_order_id, r.paint_id, r.paint_name)
     );

  perform recalculate_paint_reserved_qty(v_touched);
end;
$function$;

comment on function public.release_order_paint_reservations(text, text, text) is
  'Снимает бронь краски заказа, КРОМЕ красок с непогашенным отложенным '
  'списанием: по ним долг ещё не закрыт, и отпустить краску значит отдать её '
  'другому заказу, а потом отказать в списании при полном складе. '
  'p_reason = ''order_deleted'' снимает всё безусловно — удаление заказа '
  'нельзя запирать ничем.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Долг закрыли — бронь отпускается
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Списание гасит бронь само (used_qty), и погашенную строку убирает триггер
-- drop_settled_paint_reservation. Этот триггер закрывает ВТОРОЙ случай: долг
-- отменили — удалили строку или сняли с неё статус pending. Тогда держать
-- бронь больше не на чем.
--
-- Отпускаем только у ЗАВЕРШЁННОГО заказа: у живого бронь нужна ему самому, и
-- снятие долга не повод отдавать краску соседям.

create or replace function public.release_reserve_when_debt_gone()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_order_id text;
  v_status   text;
begin
  v_order_id := coalesce(old.order_id::text, new.order_id::text);
  if coalesce(trim(v_order_id), '') = '' then
    return null;
  end if;

  -- Долг ещё висит — ничего не трогаем.
  if exists (
    select 1 from order_paint_pending_writeoffs w
     where w.order_id::text = v_order_id and w.status = 'pending'
  ) then
    return null;
  end if;

  select o.status into v_status from orders o where o.id::text = v_order_id;
  if v_status is distinct from 'completed' then
    return null;
  end if;

  perform public.release_order_paint_reservations(
    v_order_id, 'pending_debt_closed', 'system');
  return null;
end;
$function$;

drop trigger if exists release_reserve_when_debt_gone
  on public.order_paint_pending_writeoffs;

create trigger release_reserve_when_debt_gone
  after delete or update of status on public.order_paint_pending_writeoffs
  for each row
  execute function public.release_reserve_when_debt_gone();

commit;
