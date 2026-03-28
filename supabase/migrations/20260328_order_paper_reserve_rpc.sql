-- Атомарные операции резерва бумаги для заказов.

create or replace function public.sync_order_paper_reservations(
  p_order_id text,
  p_reservations jsonb default '[]'::jsonb,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
  v_available double precision;
  v_reserved_other double precision;
  v_paper_name text;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  if p_reservations is null then
    p_reservations := '[]'::jsonb;
  end if;

  -- Валидируем вход и блокируем нужные позиции бумаги для конкурентной безопасности.
  for rec in
    with requested as (
      select
        trim(value->>'paper_id') as paper_id,
        coalesce(nullif(value->>'qty', '')::double precision, 0) as qty
      from jsonb_array_elements(p_reservations)
    ),
    aggregated as (
      select paper_id, sum(qty) as qty
      from requested
      where paper_id <> ''
      group by paper_id
    )
    select a.paper_id, a.qty, p.quantity as total_qty, p.description as paper_name
    from aggregated a
    left join papers p on p.id = a.paper_id
    order by a.paper_id
    for update of p
  loop
    if rec.qty < 0 then
      raise exception 'Нельзя зарезервировать отрицательное количество бумаги (%).', rec.paper_id;
    end if;

    if rec.total_qty is null then
      raise exception 'Бумага % не найдена на складе.', rec.paper_id;
    end if;

    select coalesce(sum(r.qty), 0)
      into v_reserved_other
      from order_paper_reservations r
     where r.paper_id = rec.paper_id
       and r.order_id <> p_order_id;

    v_available := rec.total_qty - v_reserved_other;
    if v_available < rec.qty then
      v_paper_name := coalesce(rec.paper_name, rec.paper_id);
      raise exception 'Недостаточно доступного остатка бумаги "%": доступно %, требуется %.',
        v_paper_name, round(v_available::numeric, 2), round(rec.qty::numeric, 2);
    end if;
  end loop;

  -- Upsert по каждой бумаге.
  for rec in
    with requested as (
      select
        trim(value->>'paper_id') as paper_id,
        coalesce(nullif(value->>'qty', '')::double precision, 0) as qty
      from jsonb_array_elements(p_reservations)
    )
    select paper_id, sum(qty) as qty
    from requested
    where paper_id <> ''
    group by paper_id
  loop
    if rec.qty <= 0 then
      delete from order_paper_reservations
       where order_id = p_order_id
         and paper_id = rec.paper_id;
    else
      insert into order_paper_reservations(order_id, paper_id, qty)
      values (p_order_id, rec.paper_id, rec.qty)
      on conflict (order_id, paper_id)
      do update
      set qty = excluded.qty,
          updated_at = now();
    end if;
  end loop;

  -- Удаляем резервы, которых больше нет в составе заказа.
  delete from order_paper_reservations r
   where r.order_id = p_order_id
     and not exists (
       select 1
       from jsonb_array_elements(p_reservations) j
       where trim(j->>'paper_id') = r.paper_id
         and coalesce(nullif(j->>'qty', '')::double precision, 0) > 0
     );
end;
$$;

grant execute on function public.sync_order_paper_reservations(text, jsonb, text)
to authenticated, anon;

create or replace function public.release_order_paper_reservations(
  p_order_id text,
  p_reason text default null,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  delete from order_paper_reservations
   where order_id = p_order_id;
end;
$$;

grant execute on function public.release_order_paper_reservations(text, text, text)
to authenticated, anon;

create or replace function public.finalize_order_paper_reservations(
  p_order_id text,
  p_actor text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  rec record;
begin
  if coalesce(trim(p_order_id), '') = '' then
    raise exception 'order_id is required';
  end if;

  -- Блокируем строки резерва заказа, чтобы избежать двойного списания.
  for rec in
    select r.paper_id, r.qty
    from order_paper_reservations r
    where r.order_id = p_order_id
    for update
  loop
    if rec.qty <= 0 then
      continue;
    end if;

    insert into papers_writeoffs(paper_id, qty, reason, by_name)
    values (
      rec.paper_id,
      rec.qty,
      format('Списание после завершения заказа %s', p_order_id),
      coalesce(nullif(trim(p_actor), ''), 'system')
    );
  end loop;

  delete from order_paper_reservations
   where order_id = p_order_id;
end;
$$;

grant execute on function public.finalize_order_paper_reservations(text, text)
to authenticated, anon;
