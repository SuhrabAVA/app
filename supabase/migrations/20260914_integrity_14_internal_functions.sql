-- ============================================================================
-- Целостность данных, шаг 14: служебные функции не вызываются из приложения
-- (2026-09-14)
--
-- Любая функция схемы public видна как /rest/v1/rpc/<имя>. Вошедший
-- пользователь (все устройства входят одним) мог вызвать напрямую то, что
-- должно работать только внутри других функций, например:
--   * advance_order_after_task_completion — закрыть этап и заказ, списать
--     бумагу, минуя проверки complete_task_stage;
--   * recompute_task_quantity_shares, recalculate_paint_reserved_qty — пересчёт
--     долей и броней по произвольному id;
--   * функции триггеров.
--
-- Приложение эти функции не вызывает (сверено по всем вызовам rpc в lib/).
-- Внутри SECURITY DEFINER-функций они выполняются с правами владельца, поэтому
-- отзыв права у authenticated на работу приложения не влияет — проверено
-- холостым прогоном завершения этапа, флексопечати, склада и факта заказа от
-- роли authenticated.
-- ============================================================================

begin;

-- Функции триггеров и событий: вызывать их через RPC бессмысленно.
do $revoke$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')
  loop
    execute format('revoke execute on function %s from authenticated, anon, public', f);
  end loop;
end
$revoke$;

-- Внутренние шаги, которые приложение не зовёт.
do $revoke$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'advance_order_after_task_completion',
         'recompute_task_quantity_shares',
         'recalculate_paint_reserved_qty',
         'prune_task_event_requests',
         'prune_workplace_queue_positions',
         'order_actual_qty_compute',
         'order_stage_is_last',
         'order_paper_writeoff_stage_key',
         'order_paint_pending_debt_grams',
         'paint_reservation_has_pending_debt',
         'employee_id_from_actor'
       )
  loop
    execute format('revoke execute on function %s from authenticated, anon, public', f);
  end loop;
end
$revoke$;

commit;
