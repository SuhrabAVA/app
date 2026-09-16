-- ============================================================================
-- Целостность данных, шаг 8: остаток бумаги и краски меняется только через
-- журнал склада (2026-09-14)
--
-- Что чинит
-- ---------
-- papers.quantity / paints.quantity приложение меняло напрямую, мимо журнала:
--   * возврат прибавлял остаток без записи прихода;
--   * ручная правка остатка и инвентаризация ставили число update-ом;
--   * отмена списания / прихода пересчитывала остаток на клиенте и лишь
--     дописывала «[ОТМЕНЕНО]» в причину — строка оставалась в журнале с
--     количеством;
--   * отмена инвентаризации не возвращала прежний остаток вовсе;
--   * триггер списания обрезал остаток до нуля (greatest(0, …)) и молча прятал
--     недостачу.
-- На 14.09 у 32 бумаг и 36 красок остаток не сходился с журналом
-- (последняя инвентаризация + приходы − списания).
--
-- Что делает миграция
-- -------------------
-- 1. Журнал знает больше: у прихода — источник (приход или возврат), у
--    инвентаризации — вид (пересчёт, правка, недостача, сверка) и остаток ДО
--    неё, у всех записей — отмена (когда и кем) и сотрудник.
-- 2. Триггеры журнала — единственные, кто меняет остаток. Списание больше
--    остатка обнуляет его И записывает недостачу инвентаризацией.
-- 3. Прямая правка остатка (старые версии приложения, SQL) не запрещается,
--    а сама превращается в запись журнала «правка в обход журнала» — остаток
--    и журнал больше не расходятся ни при каком пути записи.
-- 4. Запись журнала нельзя удалить и нельзя поменять ей количество — только
--    отменить (шаг 9, stock_cancel_movement).
-- 5. История: отмены с «[ОТМЕНЕНО]» получают отметку отмены; у позиций, где
--    остаток и журнал разошлись, фиксируется сверка — дальше расхождение
--    возможно только в обход всех перечисленных правил.
-- ============================================================================

begin;

-- ─── 1. Колонки ─────────────────────────────────────────────────────────────

alter table public.papers_arrivals
  add column if not exists source text not null default 'arrival',
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by text,
  add column if not exists employee_id text references public.employees(id) on delete set null;
alter table public.paints_arrivals
  add column if not exists source text not null default 'arrival',
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by text,
  add column if not exists employee_id text references public.employees(id) on delete set null;

alter table public.papers_writeoffs
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by text;
alter table public.paints_writeoffs
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by text;

alter table public.papers_inventories
  add column if not exists kind text not null default 'count',
  add column if not exists previous_qty numeric(14,3),
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by text,
  add column if not exists employee_id text references public.employees(id) on delete set null;
alter table public.paints_inventories
  add column if not exists kind text not null default 'count',
  add column if not exists previous_qty numeric(14,3),
  add column if not exists canceled_at timestamptz,
  add column if not exists canceled_by text,
  add column if not exists employee_id text references public.employees(id) on delete set null;

do $checks$
declare
  t text;
begin
  foreach t in array array['papers_arrivals', 'paints_arrivals'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_source_check');
    execute format('alter table public.%I add constraint %I check (source in (''arrival'', ''return''))', t, t || '_source_check');
  end loop;
  foreach t in array array['papers_inventories', 'paints_inventories'] loop
    execute format('alter table public.%I drop constraint if exists %I', t, t || '_kind_check');
    execute format('alter table public.%I add constraint %I check (kind in (''count'', ''correction'', ''shortage'', ''baseline''))', t, t || '_kind_check');
  end loop;
end
$checks$;

comment on column public.papers_inventories.kind is
  'count — пересчёт на складе; correction — правка остатка (в том числе прямая, в обход журнала); '
  'shortage — недостача: списали больше остатка; baseline — сверка при переходе на журнал 14.09.2026';
comment on column public.paints_inventories.kind is
  'count — пересчёт на складе; correction — правка остатка (в том числе прямая, в обход журнала); '
  'shortage — недостача: списали больше остатка; baseline — сверка при переходе на журнал 14.09.2026';
comment on column public.papers_inventories.previous_qty is 'Остаток до инвентаризации. Нужен, чтобы её можно было отменить.';
comment on column public.paints_inventories.previous_qty is 'Остаток до инвентаризации. Нужен, чтобы её можно было отменить.';

-- ─── 2. Триггеры журнала — единственные писатели остатка ────────────────────
--
-- Метка app.stock_writer = 'journal' отличает их запись от прямой правки.
-- Прежнее значение метки восстанавливается: триггеры вкладываются друг в
-- друга (списание с недостачей пишет инвентаризацию).

create or replace function public.papers_apply_arrival()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update papers set quantity = coalesce(quantity, 0) + new.qty, updated_at = now() where id = new.paper_id;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$;

create or replace function public.paints_apply_arrival()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update paints set quantity = coalesce(quantity, 0) + new.qty, updated_at = now() where id = new.paint_id;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$;

create or replace function public.papers_apply_writeoff()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  v_prev text := coalesce(current_setting('app.stock_writer', true), '');
  v_stock numeric;
begin
  select quantity into v_stock from papers where id = new.paper_id for update;
  perform set_config('app.stock_writer', 'journal', true);
  if coalesce(v_stock, 0) >= new.qty then
    update papers set quantity = v_stock - new.qty, updated_at = now() where id = new.paper_id;
  else
    -- Списали больше, чем числится: остаток обнуляется, а недостача не
    -- исчезает — она остаётся записью, которую видно в журнале.
    update papers set quantity = 0, updated_at = now() where id = new.paper_id;
    insert into papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.paper_id, 0, coalesce(v_stock, 0) - new.qty, 'shortage',
            format('Недостача: списано %s при остатке %s', new.qty, coalesce(v_stock, 0)),
            new.by_name, new.created_by);
  end if;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$;

create or replace function public.paints_apply_writeoff()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  v_prev text := coalesce(current_setting('app.stock_writer', true), '');
  v_stock numeric;
begin
  select quantity into v_stock from paints where id = new.paint_id for update;
  perform set_config('app.stock_writer', 'journal', true);
  if coalesce(v_stock, 0) >= new.qty then
    update paints set quantity = v_stock - new.qty, updated_at = now() where id = new.paint_id;
  else
    update paints set quantity = 0, updated_at = now() where id = new.paint_id;
    insert into paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.paint_id, 0, coalesce(v_stock, 0) - new.qty, 'shortage',
            format('Недостача: списано %s при остатке %s', new.qty, coalesce(v_stock, 0)),
            new.by_name, new.created_by);
  end if;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$;

create or replace function public.papers_apply_inventory()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update papers set quantity = new.counted_qty, updated_at = now()
   where id = new.paper_id and quantity is distinct from new.counted_qty;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$;

create or replace function public.paints_apply_inventory()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_prev text := coalesce(current_setting('app.stock_writer', true), '');
begin
  perform set_config('app.stock_writer', 'journal', true);
  update paints set quantity = new.counted_qty, updated_at = now()
   where id = new.paint_id and quantity is distinct from new.counted_qty;
  perform set_config('app.stock_writer', v_prev, true);
  return new;
end
$function$;

-- Перед записью: остаток до инвентаризации и сотрудник.
create or replace function public.stock_journal_before_insert()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  -- Вложенные if, а не «and»: plpgsql не обещает короткое замыкание, а у
  -- приходов поля previous_qty нет.
  if tg_table_name = 'papers_inventories' then
    if new.previous_qty is null then
      select quantity into new.previous_qty from papers where id = new.paper_id;
    end if;
  elsif tg_table_name = 'paints_inventories' then
    if new.previous_qty is null then
      select quantity into new.previous_qty from paints where id = new.paint_id;
    end if;
  end if;
  if new.employee_id is null then
    new.employee_id := public.employee_id_from_actor(new.by_name);
  end if;
  return new;
end
$function$;

do $triggers$
declare
  t text;
begin
  foreach t in array array['papers_arrivals', 'paints_arrivals', 'papers_inventories', 'paints_inventories'] loop
    execute format('drop trigger if exists aa_stock_journal_before_insert on public.%I', t);
    execute format('create trigger aa_stock_journal_before_insert before insert on public.%I '
                   'for each row execute function public.stock_journal_before_insert()', t);
  end loop;
end
$triggers$;

-- ─── 3. Прямая правка остатка становится записью журнала ────────────────────

create or replace function public.stock_direct_change_to_journal()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare
  v_old numeric := case when tg_op = 'UPDATE' then old.quantity else 0 end;
  v_actor text := coalesce(nullif(current_setting('app.stock_actor', true), ''), 'не указан');
begin
  if coalesce(current_setting('app.stock_writer', true), '') = 'journal' then return null; end if;
  if new.quantity is not distinct from v_old then return null; end if;

  perform set_config('app.stock_writer', 'journal', true);
  if tg_table_name = 'papers' then
    insert into papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.id, coalesce(new.quantity, 0), v_old, 'correction',
            case when tg_op = 'INSERT' then 'Начальный остаток карточки (без прихода)'
                 else 'Остаток изменён напрямую, в обход журнала' end,
            v_actor, auth.uid());
  else
    insert into paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name, created_by)
    values (new.id, coalesce(new.quantity, 0), v_old, 'correction',
            case when tg_op = 'INSERT' then 'Начальный остаток карточки (без прихода)'
                 else 'Остаток изменён напрямую, в обход журнала' end,
            v_actor, auth.uid());
  end if;
  perform set_config('app.stock_writer', '', true);
  return null;
end
$function$;

comment on function public.stock_direct_change_to_journal() is
  'Любое изменение остатка бумаги/краски не через журнал склада записывается '
  'в журнал инвентаризацией вида correction. Так остаток и журнал не '
  'расходятся даже при записи старой версией приложения или руками в SQL.';

do $triggers$
declare
  t text;
begin
  foreach t in array array['papers', 'paints'] loop
    execute format('drop trigger if exists stock_direct_change_to_journal_upd on public.%I', t);
    execute format('create trigger stock_direct_change_to_journal_upd after update of quantity on public.%I '
                   'for each row execute function public.stock_direct_change_to_journal()', t);
    execute format('drop trigger if exists stock_direct_change_to_journal_ins on public.%I', t);
    execute format('create trigger stock_direct_change_to_journal_ins after insert on public.%I '
                   'for each row when (coalesce(new.quantity, 0) <> 0) '
                   'execute function public.stock_direct_change_to_journal()', t);
  end loop;
end
$triggers$;

-- ─── 4. Запись журнала не удаляется и не переписывается ─────────────────────

create or replace function public.stock_journal_guard()
returns trigger language plpgsql as $function$
declare
  v_item_exists boolean;
begin
  if tg_table_name like 'papers_%' then
    select exists (select 1 from papers where id = old.paper_id) into v_item_exists;
  else
    select exists (select 1 from paints where id = old.paint_id) into v_item_exists;
  end if;

  -- Каскад от удаления самой карточки склада не мешаем: карточки уже нет.
  if not v_item_exists then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  if tg_op = 'DELETE' then
    raise exception using
      message = 'Запись журнала склада удалить нельзя — её можно только отменить.',
      errcode = 'check_violation';
  end if;

  raise exception using
    message = 'Количество и позицию в записи журнала склада менять нельзя — отмените запись и внесите новую.',
    errcode = 'check_violation';
end
$function$;

do $triggers$
declare
  t text;
  c text;
begin
  foreach t in array array['papers_arrivals', 'paints_arrivals', 'papers_writeoffs', 'paints_writeoffs'] loop
    c := case when t like 'papers_%' then 'paper_id' else 'paint_id' end;
    execute format('drop trigger if exists stock_journal_guard_del on public.%I', t);
    execute format('create trigger stock_journal_guard_del before delete on public.%I '
                   'for each row execute function public.stock_journal_guard()', t);
    execute format('drop trigger if exists stock_journal_guard_upd on public.%I', t);
    execute format('create trigger stock_journal_guard_upd before update of qty, %s on public.%I '
                   'for each row when (old.qty is distinct from new.qty or old.%s is distinct from new.%s) '
                   'execute function public.stock_journal_guard()', c, t, c, c);
  end loop;
  foreach t in array array['papers_inventories', 'paints_inventories'] loop
    c := case when t like 'papers_%' then 'paper_id' else 'paint_id' end;
    execute format('drop trigger if exists stock_journal_guard_del on public.%I', t);
    execute format('create trigger stock_journal_guard_del before delete on public.%I '
                   'for each row execute function public.stock_journal_guard()', t);
    execute format('drop trigger if exists stock_journal_guard_upd on public.%I', t);
    execute format('create trigger stock_journal_guard_upd before update of counted_qty, %s on public.%I '
                   'for each row when (old.counted_qty is distinct from new.counted_qty or old.%s is distinct from new.%s) '
                   'execute function public.stock_journal_guard()', c, t, c, c);
  end loop;
end
$triggers$;

-- ─── 5. История ─────────────────────────────────────────────────────────────

-- 5.1. Отмены старым способом — пометка «[ОТМЕНЕНО]» в тексте. Точного
-- момента отмены нет; ставится момент самой записи.
update public.papers_writeoffs set canceled_at = created_at, canceled_by = 'до 14.09.2026'
 where canceled_at is null and reason ilike '%[ОТМЕНЕНО]%';
update public.paints_writeoffs set canceled_at = created_at, canceled_by = 'до 14.09.2026'
 where canceled_at is null and reason ilike '%[ОТМЕНЕНО]%';
update public.papers_arrivals set canceled_at = created_at, canceled_by = 'до 14.09.2026'
 where canceled_at is null and note ilike '%[ОТМЕНЕНО]%';
update public.paints_arrivals set canceled_at = created_at, canceled_by = 'до 14.09.2026'
 where canceled_at is null and note ilike '%[ОТМЕНЕНО]%';
update public.papers_inventories set canceled_at = created_at, canceled_by = 'до 14.09.2026'
 where canceled_at is null and note ilike '%[ОТМЕНЕНО]%';
update public.paints_inventories set canceled_at = created_at, canceled_by = 'до 14.09.2026'
 where canceled_at is null and note ilike '%[ОТМЕНЕНО]%';

-- 5.2. Сотрудник у старых приходов и инвентаризаций.
update public.papers_arrivals set employee_id = public.employee_id_from_actor(by_name)
 where employee_id is null and public.employee_id_from_actor(by_name) is not null;
update public.paints_arrivals set employee_id = public.employee_id_from_actor(by_name)
 where employee_id is null and public.employee_id_from_actor(by_name) is not null;
update public.papers_inventories set employee_id = public.employee_id_from_actor(by_name)
 where employee_id is null and public.employee_id_from_actor(by_name) is not null;
update public.paints_inventories set employee_id = public.employee_id_from_actor(by_name)
 where employee_id is null and public.employee_id_from_actor(by_name) is not null;

-- 5.3. Сверка: где остаток разошёлся с журналом, фиксируем фактический
-- остаток записью baseline. Остаток не меняется; расхождение остаётся в
-- истории текстом записи.
insert into public.papers_inventories(paper_id, counted_qty, previous_qty, kind, note, by_name)
select p.id, p.quantity, p.quantity, 'baseline',
       format('Сверка при переходе на журнал 14.09.2026: по журналу %s, фактический остаток %s',
              round(l.ledger, 3), p.quantity),
       'system'
  from public.papers p
  cross join lateral (
    select coalesce(inv.counted_qty, 0)
           + coalesce((select sum(a.qty) from public.papers_arrivals a
                        where a.paper_id = p.id and a.canceled_at is null
                          and (inv.created_at is null or a.created_at > inv.created_at)), 0)
           - coalesce((select sum(w.qty) from public.papers_writeoffs w
                        where w.paper_id = p.id and w.canceled_at is null
                          and (inv.created_at is null or w.created_at > inv.created_at)), 0) as ledger
      from (select null::int) dummy
      left join lateral (
        select i.counted_qty, i.created_at from public.papers_inventories i
         where i.paper_id = p.id and i.canceled_at is null
         order by i.created_at desc limit 1) inv on true
  ) l
 where abs(p.quantity - l.ledger) > 0.001;

insert into public.paints_inventories(paint_id, counted_qty, previous_qty, kind, note, by_name)
select p.id, p.quantity, p.quantity, 'baseline',
       format('Сверка при переходе на журнал 14.09.2026: по журналу %s, фактический остаток %s',
              round(l.ledger, 3), p.quantity),
       'system'
  from public.paints p
  cross join lateral (
    select coalesce(inv.counted_qty, 0)
           + coalesce((select sum(a.qty) from public.paints_arrivals a
                        where a.paint_id = p.id and a.canceled_at is null
                          and (inv.created_at is null or a.created_at > inv.created_at)), 0)
           - coalesce((select sum(w.qty) from public.paints_writeoffs w
                        where w.paint_id = p.id and w.canceled_at is null
                          and (inv.created_at is null or w.created_at > inv.created_at)), 0) as ledger
      from (select null::int) dummy
      left join lateral (
        select i.counted_qty, i.created_at from public.paints_inventories i
         where i.paint_id = p.id and i.canceled_at is null
         order by i.created_at desc limit 1) inv on true
  ) l
 where abs(p.quantity - l.ledger) > 0.001;

commit;
