-- ============================================================================
-- Целостность данных, шаг 4: отчёт о здоровье данных (2026-09-14)
--
-- Зачем
-- -----
-- Все сбои учёта, найденные диагностикой 14.09, жили неделями незамеченными:
-- бронь под долгом, открытые интервалы, этапы без личных долей, отсутствующий
-- триггер. Каждый раз их находили по жалобе и вручную, запросами к базе.
--
-- data_health_report() — те же проверки одной функцией. Одна строка — одна
-- проверка: код, серьёзность, число затронутых записей, что делать и до
-- десяти примеров. Пустых проверок в выдаче нет: всё, что вернулось, требует
-- внимания.
--
-- Функция только читает. Новые проверки дописываются сюда же — по мере того,
-- как находятся новые виды сбоев.
-- ============================================================================

begin;

create or replace function public.data_health_report()
returns table (
  code text,
  severity text,
  title text,
  affected bigint,
  hint text,
  sample jsonb
)
language sql
stable
security definer
set search_path to 'public'
as $function$
with
-- ─── краска: отложенные списания ──────────────────────────────────────────
debts as (
  select w.order_id, w.paint_id, max(w.paint_name) as paint_name,
         sum(coalesce(w.actual_used_amount, w.planned_amount, 0)) as debt,
         min(w.created_at) as since
    from order_paint_pending_writeoffs w
   where w.status = 'pending'
   group by w.order_id, w.paint_id
),
debt_cover as (
  select d.*,
         coalesce((
           select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
             from order_paint_reservations r
            where r.order_id = d.order_id
              and (r.paint_id = d.paint_id
                   or (d.paint_id is null
                       and normalize_paint_name(r.paint_name) = normalize_paint_name(d.paint_name)))
         ), 0) as covered,
         p.quantity as stock,
         o.customer,
         o.status as order_status
    from debts d
    left join paints p on p.id = d.paint_id
    left join orders o on o.id::text = d.order_id
),
-- ─── задачи ────────────────────────────────────────────────────────────────
task_facts as (
  select t.id, t.order_id, t.stage_id, t.status, t.completed_at,
         (select w.name from workplaces w where w.id::text = t.stage_id) as workplace,
         exists (
           select 1 from jsonb_array_elements(task_comments_to_array(t.comments)) c
            where c->>'type' = 'time_event'
              and task_json_payload(c->>'text') is not null
              and (task_json_payload(c->>'text')->>'endTime') is null
         ) as has_open_interval,
         exists (
           select 1 from jsonb_array_elements(task_comments_to_array(t.comments)) c
            where c->>'type' = 'quantity_stage_total'
              and task_quantity_value(c->>'text') > 0
         ) as has_stage_total,
         exists (
           select 1 from jsonb_array_elements(task_comments_to_array(t.comments)) c
            where c->>'type' in ('quantity_done', 'quantity_share', 'quantity_team_total')
         ) as has_personal
    from tasks t
),
dup_qty as (
  select distinct t.id as task_id, a->>'userId' as user_id, a->>'text' as qty_text
    from tasks t
    cross join lateral jsonb_array_elements(task_comments_to_array(t.comments)) a
    cross join lateral jsonb_array_elements(task_comments_to_array(t.comments)) b
   where a->>'type' = 'quantity_done'
     and b->>'type' = 'quantity_done'
     and a->>'id' is distinct from b->>'id'
     and a->>'userId' = b->>'userId'
     and a->>'text' = b->>'text'
     and task_comment_millis(b->>'timestamp') > task_comment_millis(a->>'timestamp')
     and task_comment_millis(b->>'timestamp') - task_comment_millis(a->>'timestamp') < 180000
),
-- ─── бумага ────────────────────────────────────────────────────────────────
paper_stage as (
  select o.id, o.customer, order_paper_writeoff_stage_key(o.id::text) as stage_key,
         (select sum(r.qty) from order_paper_reservations r where r.order_id = o.id) as reserved_m
    from orders o
   where o.paper_written_off_at is null
     and o.status not in ('draft', 'completed')
),
-- ─── склад: остаток против журнала ────────────────────────────────────────
paper_ledger as (
  select p.id, p.description, p.quantity,
         coalesce(inv.counted_qty, 0)
         + coalesce((select sum(a.qty) from papers_arrivals a
                      where a.paper_id = p.id and (inv.created_at is null or a.created_at > inv.created_at)), 0)
         - coalesce((select sum(w.qty) from papers_writeoffs w
                      where w.paper_id = p.id and (inv.created_at is null or w.created_at > inv.created_at)), 0)
           as ledger
    from papers p
    left join lateral (
      select i.counted_qty, i.created_at from papers_inventories i
       where i.paper_id = p.id order by i.created_at desc limit 1
    ) inv on true
),
paint_ledger as (
  select p.id, p.description, p.quantity,
         coalesce(inv.counted_qty, 0)
         + coalesce((select sum(a.qty) from paints_arrivals a
                      where a.paint_id = p.id and (inv.created_at is null or a.created_at > inv.created_at)), 0)
         - coalesce((select sum(w.qty) from paints_writeoffs w
                      where w.paint_id = p.id and (inv.created_at is null or w.created_at > inv.created_at)), 0)
           as ledger
    from paints p
    left join lateral (
      select i.counted_qty, i.created_at from paints_inventories i
       where i.paint_id = p.id order by i.created_at desc limit 1
    ) inv on true
),
-- ─── обязательные триггеры ────────────────────────────────────────────────
required_triggers(tbl, name) as (
  values
    ('tasks', 'tasks_close_intervals_on_complete'),
    ('tasks', 'tasks_guard_active_assignees'),
    ('paints_writeoffs', 'trg_paints_writeoff_apply'),
    ('paints_arrivals', 'trg_paints_arrival_apply'),
    ('paints_inventories', 'trg_paints_inventory_apply'),
    ('papers_writeoffs', 'trg_papers_writeoff_apply'),
    ('papers_arrivals', 'trg_papers_arrival_apply'),
    ('papers_inventories', 'trg_papers_inventory_apply'),
    ('order_paint_pending_writeoffs', 'release_reserve_when_debt_gone')
),
missing_triggers as (
  select rt.tbl, rt.name
    from required_triggers rt
   where not exists (
     select 1 from pg_trigger tg
      where tg.tgrelid = to_regclass('public.' || rt.tbl)
        and tg.tgname = rt.name
        and not tg.tgisinternal
   )
),
checks as (
  select 'missing_triggers' as code, 'critical' as severity,
         'Нет обязательного триггера' as title,
         (select count(*) from missing_triggers) as affected,
         'Без триггера остаток склада или интервалы времени перестают обновляться. Накатить миграцию, создающую триггер.' as hint,
         (select jsonb_agg(tbl || '.' || name) from missing_triggers) as sample

  union all
  select 'paint_debt_without_reserve', 'critical',
         'Краска под отложенным списанием без брони',
         count(*),
         'Краску заберёт другой заказ, списание долга упадёт с «Недостаточно краски». Если остатка не хватает — инвентаризация.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name,
                                      'долг_г', debt, 'бронь_г', covered, 'остаток_г', stock) x
              from debt_cover where debt > covered + 0.5 order by since limit 10) s)
    from debt_cover where debt > covered + 0.5

  union all
  select 'paint_debt_exceeds_stock', 'warning',
         'Долг по краске больше складского остатка',
         count(*),
         'Списать такой долг нельзя — проверка остатка откажет. Нужна инвентаризация краски.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name,
                                      'долг_г', debt, 'остаток_г', stock) x
              from debt_cover where paint_id is not null and debt > coalesce(stock, 0) order by since limit 10) s)
    from debt_cover where paint_id is not null and debt > coalesce(stock, 0)

  union all
  select 'paint_debt_unknown_paint', 'warning',
         'Отложенное списание без краски склада',
         count(*),
         'Имя краски в долге не совпало ни с одной карточкой склада. Завести краску или исправить имя.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name, 'долг_г', debt) x
              from debt_cover where paint_id is null order by since limit 10) s)
    from debt_cover where paint_id is null

  union all
  select 'paint_debt_stale', 'info',
         'Отложенное списание висит больше 14 дней',
         count(*),
         'Долг держит бронь краски. Если краску уже израсходовали иначе — списать вручную.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(customer, order_id), 'краска', paint_name,
                                      'с', since::date, 'долг_г', debt) x
              from debt_cover where since < now() - interval '14 days' order by since limit 10) s)
    from debt_cover where since < now() - interval '14 days'

  union all
  select 'completed_task_open_interval', 'critical',
         'Завершённый этап с открытым интервалом времени',
         count(*),
         'Время «тикает» после завершения: неверные часы и доли. Проверить триггер tasks_close_intervals_on_complete.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('задача', id, 'рм', workplace) x
              from task_facts where status = 'completed' and has_open_interval limit 10) s)
    from task_facts where status = 'completed' and has_open_interval

  union all
  select 'completed_task_without_completed_at', 'warning',
         'Завершённый этап без времени завершения',
         count(*),
         'Время завершения берётся из updated_at и сдвигается любой правкой строки.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('задача', id, 'рм', workplace) x
              from task_facts where status = 'completed' and completed_at is null limit 10) s)
    from task_facts where status = 'completed' and completed_at is null

  union all
  select 'completed_task_without_personal_qty', 'critical',
         'Закрытый этап с тиражом, но без личного количества',
         count(*),
         'Выработка сотрудников не попадёт в аналитику и сдельную. Выполнить recompute_task_quantity_shares(задача).',
         (select jsonb_agg(x) from (
            select jsonb_build_object('задача', id, 'рм', workplace) x
              from task_facts where status = 'completed' and has_stage_total and not has_personal limit 10) s)
    from task_facts where status = 'completed' and has_stage_total and not has_personal

  union all
  select 'duplicate_quantity_done', 'warning',
         'Повтор личного количества (тот же человек и число в пределах 3 минут)',
         count(*),
         'Скорее всего двойное нажатие «Завершить». Сверить с цехом и удалить лишнюю запись через правку количества.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('задача', task_id, 'сотрудник', user_id, 'количество', qty_text) x
              from dup_qty limit 10) s)
    from dup_qty

  union all
  select 'paper_stage_closed_not_written_off', 'warning',
         'Этап списания бумаги закрыт, бумага не списана',
         count(*),
         'Бронь держит метры, которых на складе физически нет. Выполнить finalize_order_paper_reservations(заказ).',
         (select jsonb_agg(x) from (
            select jsonb_build_object('заказ', coalesce(ps.customer, ps.id::text), 'бронь_м', ps.reserved_m) x
              from paper_stage ps
             where ps.stage_key is not null and coalesce(ps.reserved_m, 0) > 0
               and exists (select 1 from tasks t where t.order_id = ps.id
                            and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key)
               and not exists (select 1 from tasks t where t.order_id = ps.id
                                and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key
                                and t.status <> 'completed')
             limit 10) s)
    from paper_stage ps
   where ps.stage_key is not null and coalesce(ps.reserved_m, 0) > 0
     and exists (select 1 from tasks t where t.order_id = ps.id
                  and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key)
     and not exists (select 1 from tasks t where t.order_id = ps.id
                      and coalesce(nullif(t.stage_group_key, ''), t.stage_id) = ps.stage_key
                      and t.status <> 'completed')

  union all
  select 'paint_reserved_cache_mismatch', 'warning',
         'Кэш брони краски не совпадает с бронями заказов',
         count(*),
         'Выполнить recalculate_paint_reserved_qty(null) для этих красок.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('краска', p.description, 'кэш_г', p.reserved_qty) x
              from paints p
             where abs(coalesce(p.reserved_qty, 0) - coalesce((
                     select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
                       from order_paint_reservations r where r.paint_id = p.id), 0)) > 0.5
             limit 10) s)
    from paints p
   where abs(coalesce(p.reserved_qty, 0) - coalesce((
           select sum(greatest(r.reserved_qty - r.used_qty - r.released_qty, 0))
             from order_paint_reservations r where r.paint_id = p.id), 0)) > 0.5

  union all
  select 'paper_stock_ledger_mismatch', 'info',
         'Остаток бумаги не сходится с журналом склада',
         count(*),
         'Остаток правили в обход журнала (возврат, ручная правка, отмена списания). Провести инвентаризацию.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('бумага', description, 'остаток', quantity, 'по_журналу', round(ledger::numeric, 2)) x
              from paper_ledger where abs(quantity - ledger) > 1 order by abs(quantity - ledger) desc limit 10) s)
    from paper_ledger where abs(quantity - ledger) > 1

  union all
  select 'paint_stock_ledger_mismatch', 'info',
         'Остаток краски не сходится с журналом склада',
         count(*),
         'Остаток правили в обход журнала (возврат, ручная правка, отмена списания). Провести инвентаризацию.',
         (select jsonb_agg(x) from (
            select jsonb_build_object('краска', description, 'остаток', quantity, 'по_журналу', round(ledger::numeric, 2)) x
              from paint_ledger where abs(quantity - ledger) > 1 order by abs(quantity - ledger) desc limit 10) s)
    from paint_ledger where abs(quantity - ledger) > 1

  union all
  select 'orphan_paint_rows', 'info',
         'Брони и долги краски удалённых заказов',
         (select count(*) from order_paint_reservations r
           where not exists (select 1 from orders o where o.id::text = r.order_id))
         + (select count(*) from order_paint_pending_writeoffs w
             where w.status = 'pending'
               and not exists (select 1 from orders o where o.id::text = w.order_id)),
         'Заказа нет, а строки остались. Бронь таких строк занимает краску зря.',
         null
)
select c.code, c.severity, c.title, c.affected, c.hint, c.sample
  from checks c
 where c.affected > 0
 order by case c.severity when 'critical' then 0 when 'warning' then 1 else 2 end,
          c.affected desc;
$function$;

comment on function public.data_health_report() is
  'Проверки целостности учёта: брони и долги краски, интервалы и доли этапов, '
  'списание бумаги, сверка склада с журналом, обязательные триггеры. '
  'Возвращает только проверки, нашедшие проблемы. Только чтение.';

revoke execute on function public.data_health_report() from public, anon;
grant execute on function public.data_health_report() to authenticated, service_role;

commit;
