-- Правка красок в НЕЗАПУЩЕННОМ заказе не должна отклоняться (2026-09-09).
--
-- Симптом: менеджер открывает черновик (или «Готов к запуску»), меняет или
-- удаляет краску, и сохранение падает с
-- «Краска «X» перешла из заказа «Y» и ещё не списана — удалить её из списка
-- нельзя». Правки красок теряются целиком: save_order_paints пересобирает
-- список паттерном delete+insert, отложенный триггер бьёт по COMMIT и
-- откатывает RPC, тогда как сам заказ обновился отдельным запросом раньше.
--
-- Причина в ширине правила из 20260717: непогашенная строка
-- order_paint_pending_writeoffs замораживала одноимённую краску во ВСЕХ
-- прочих заказах системы. Переходящая краска физически лежит на машине и
-- принадлежит заказу-источнику; на неё «наткнётся» тот заказ, который дойдёт
-- до флексопечати следующим (getPendingFlexPaintWriteoffs подбирает
-- pending-строки по совпадению имени с красками ТЕКУЩЕГО заказа). План
-- незапущенного заказа к этому отношения не имеет: он ещё ничего не печатал,
-- и запрещать менеджеру править его состав нечем.
--
-- Правило сужено до заказов, которые действительно в производстве
-- (assignment_created и не completed): там список красок — это то, что
-- оператор увидит в диалоге списания, и потерять переходящую краску можно
-- по-настоящему. Заодно перестают кусаться СИРОТЫ: order_paint_pending_writeoffs
-- не имеет FK на orders, и pending-строки удалённых заказов оставались
-- вечными блокировщиками.

create or replace function public.guard_carryover_paint_removal()
returns trigger
language plpgsql
as $$
declare
  v_name text := public.normalize_paint_name(old.name);
  v_assignment_created boolean;
  v_status text;
  v_pending record;
  v_customer text;
begin
  if v_name = '' then
    return null;
  end if;

  -- Заказ удалён целиком в этой же транзакции (каскад) — список красок
  -- заказа перестаёт существовать, защищать нечего.
  select o.assignment_created, o.status
    into v_assignment_created, v_status
  from public.orders o
  where o.id = old.order_id;

  if not found then
    return null;
  end if;

  -- Дозапускной заказ — это план, а не производство: его состав правят
  -- свободно. Завершённый заказ красок больше не расходует.
  if not coalesce(v_assignment_created, false)
     or coalesce(v_status, '') = 'completed' then
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

  -- Сирота (заказ-источник удалён) блокировать ничего не может: показать
  -- такую строку оператору всё равно негде.
  select w.id, w.order_id
    into v_pending
  from public.order_paint_pending_writeoffs w
  where w.status = 'pending'
    and w.order_id <> old.order_id::text
    and public.normalize_paint_name(w.paint_name) = v_name
    and exists (select 1 from public.orders o2 where o2.id::text = w.order_id)
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
