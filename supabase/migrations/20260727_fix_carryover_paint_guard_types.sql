-- Фикс 42883 «operator does not exist: text <> uuid» при удалении заказа
-- (2026-07-27).
--
-- Причина: guard_carryover_paint_removal (миграция 20260717) сравнивает
-- order_paint_pending_writeoffs.order_id (тип TEXT) с order_paints.order_id
-- (тип UUID) напрямую. Postgres не имеет оператора text <> uuid, поэтому
-- запрос падает на этапе планирования — независимо от того, есть ли вообще
-- pending-строки. Любое удаление заказа делает DELETE из order_paints и
-- получало 42883, откатывая удаление целиком.
--
-- Исправление: приводим uuid к text (а не наоборот) — в текстовой колонке
-- могут лежать значения, не являющиеся валидными uuid, и обратный каст
-- ломал бы триггер на них.

create or replace function public.guard_carryover_paint_removal()
returns trigger
language plpgsql
as $$
declare
  v_name text := public.normalize_paint_name(old.name);
  v_pending record;
  v_customer text;
begin
  if v_name = '' then
    return null;
  end if;

  -- Заказ удалён целиком в этой же транзакции (каскад) — список красок
  -- заказа перестаёт существовать, защищать нечего.
  if not exists (select 1 from public.orders o where o.id = old.order_id) then
    return null;
  end if;

  -- Паттерн delete+insert: если на момент COMMIT краска с таким именем
  -- снова есть в списке заказа, удаления по сути не было.
  if exists (
    select 1
    from public.order_paints p
    where p.order_id = old.order_id
      and public.normalize_paint_name(p.name) = v_name
  ) then
    return null;
  end if;

  select w.id, w.order_id
    into v_pending
  from public.order_paint_pending_writeoffs w
  where w.status = 'pending'
    and w.order_id <> old.order_id::text
    and public.normalize_paint_name(w.paint_name) = v_name
  order by w.created_at
  limit 1;

  if v_pending.id is null then
    return null;
  end if;

  select o.customer into v_customer
  from public.orders o
  where o.id::text = v_pending.order_id;

  -- Текст показывается пользователю как есть (_humanizeRpcError берёт message).
  raise exception 'Краска «%» перешла из заказа «%» и ещё не списана — удалить её из списка нельзя',
    old.name,
    coalesce(nullif(v_customer, ''), v_pending.order_id)
    using errcode = 'P0001';
end;
$$;
