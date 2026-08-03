-- Защита переходящих красок (задача «Флексопечать», 2026-07-17).
-- Правило: пока по краске существует несписанная запись
-- order_paint_pending_writeoffs (status = 'pending') из ДРУГОГО заказа,
-- эту краску нельзя убрать из списка красок заказа (order_paints).
--
-- Реализовано отложенным constraint-триггером (проверка в момент COMMIT),
-- а не проверкой внутри save_order_paints: RPC может пересобирать список
-- паттерном «удалить все строки и вставить заново», поэтому важно только
-- итоговое состояние списка на конец транзакции. Триггер заодно закрывает
-- любые обходные пути записи (другие RPC, прямые DELETE/UPDATE).
--
-- Сопоставление красок — по нормализованному имени (trim + lower +
-- схлопывание пробелов), как в Dart (_normalizePaintNameForMatching):
-- колонки paint_id в order_paints нет, матчинг в приложении фактически
-- работает по имени.

create or replace function public.normalize_paint_name(value text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(btrim(coalesce(value, '')), '\s+', ' ', 'g'));
$$;

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
    and w.order_id <> old.order_id
    and public.normalize_paint_name(w.paint_name) = v_name
  order by w.created_at
  limit 1;

  if v_pending.id is null then
    return null;
  end if;

  select o.customer into v_customer
  from public.orders o
  where o.id = v_pending.order_id;

  -- Текст показывается пользователю как есть (_humanizeRpcError берёт message).
  raise exception 'Краска «%» перешла из заказа «%» и ещё не списана — удалить её из списка нельзя',
    old.name,
    coalesce(nullif(v_customer, ''), v_pending.order_id::text)
    using errcode = 'P0001';
end;
$$;

drop trigger if exists trg_guard_carryover_paint_removal on public.order_paints;

create constraint trigger trg_guard_carryover_paint_removal
after delete or update of name on public.order_paints
deferrable initially deferred
for each row
execute function public.guard_carryover_paint_removal();

-- Ускоряет поиск pending-строк по нормализованному имени.
create index if not exists idx_oppw_pending_norm_name
  on public.order_paint_pending_writeoffs (public.normalize_paint_name(paint_name))
  where status = 'pending';
