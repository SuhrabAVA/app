-- ============================================================================
-- Целостность данных, шаг 15: инвентаризация со старых сборок — одна запись
-- журнала вместо двух (2026-09-15)
--
-- Что чинит
-- ---------
-- Старая сборка (до 14.09) проводит инвентаризацию бумаги и краски в два
-- запроса: сначала PATCH papers.quantity, затем вставка в *_inventories.
-- После шага 8 прямое изменение остатка само пишет в журнал запись
-- kind='correction' «Остаток изменён напрямую, в обход журнала» с автором
-- «не указан». Следом приходит настоящая запись инвентаризации — и в журнале
-- склада одна инвентаризация видна дважды, причём у второй previous_qty уже
-- равен новому остатку (разницы не видно), а у первой нет автора.
-- Живой случай: 14.09 13:17–13:22, три инвентаризации бумаги — шесть строк.
--
-- Что делает миграция
-- -------------------
-- Если вставляется обычная инвентаризация (kind='count'), а последняя запись
-- журнала по этой позиции — автоматическая «прямая правка» не старше 2 минут
-- с тем же количеством, и остаток с тех пор не менялся, то вставка не
-- создаёт новую строку: автоматическая запись превращается в инвентаризацию
-- с автором и заметкой из вставки. previous_qty остаётся настоящим — тем, что
-- был до правки.
--
-- Новая сборка идёт через stock_set_quantity и под условие не попадает.
-- Когда все устройства обновятся, условие просто перестанет срабатывать.
-- ============================================================================

begin;

create or replace function public.stock_journal_before_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_merge_id uuid;
begin
  -- Вложенные if, а не «and»: plpgsql не обещает короткое замыкание, а у
  -- приходов поля previous_qty нет.
  if tg_table_name = 'papers_inventories' then
    if new.kind = 'count' then
      select i.id into v_merge_id
        from (select * from papers_inventories
               where paper_id = new.paper_id
               order by created_at desc, id desc
               limit 1) i
       where i.kind = 'correction'
         and i.canceled_at is null
         and i.by_name = 'не указан'
         and i.note = 'Остаток изменён напрямую, в обход журнала'
         and i.counted_qty = new.counted_qty
         and i.created_at > now() - interval '2 minutes'
         and exists (select 1 from papers p
                      where p.id = new.paper_id and p.quantity = new.counted_qty);
      if v_merge_id is not null then
        update papers_inventories
           set kind = 'count',
               by_name = coalesce(new.by_name, by_name),
               employee_id = coalesce(new.employee_id,
                                      public.employee_id_from_actor(new.by_name),
                                      employee_id),
               note = new.note,
               created_by = coalesce(new.created_by, created_by)
         where id = v_merge_id;
        return null;
      end if;
    end if;
    if new.previous_qty is null then
      select quantity into new.previous_qty from papers where id = new.paper_id;
    end if;
  elsif tg_table_name = 'paints_inventories' then
    if new.kind = 'count' then
      select i.id into v_merge_id
        from (select * from paints_inventories
               where paint_id = new.paint_id
               order by created_at desc, id desc
               limit 1) i
       where i.kind = 'correction'
         and i.canceled_at is null
         and i.by_name = 'не указан'
         and i.note = 'Остаток изменён напрямую, в обход журнала'
         and i.counted_qty = new.counted_qty
         and i.created_at > now() - interval '2 minutes'
         and exists (select 1 from paints p
                      where p.id = new.paint_id and p.quantity = new.counted_qty);
      if v_merge_id is not null then
        update paints_inventories
           set kind = 'count',
               by_name = coalesce(new.by_name, by_name),
               employee_id = coalesce(new.employee_id,
                                      public.employee_id_from_actor(new.by_name),
                                      employee_id),
               note = new.note,
               created_by = coalesce(new.created_by, created_by)
         where id = v_merge_id;
        return null;
      end if;
    end if;
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

revoke execute on function public.stock_journal_before_insert() from public, anon, authenticated;

-- Уже склеенные пары 14.09 не трогаем: записи журнала не переписываются
-- задним числом, а данные в них верные (остаток сходится).

commit;
