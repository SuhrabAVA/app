begin;

with allowed_tables(object_name, requires_golden_query, reason) as (
  values
    ('actual_qty_formulas', false, 'Справочник формул фактического количества.'),
    ('analytics', true, 'Производственная аналитика; расчёты только по золотым запросам.'),
    ('claims', false, 'Претензии по производству.'),
    ('employee_attendance', false, 'Посещаемость; персональные поля маскируются.'),
    ('employee_positions', false, 'Связь сотрудников и должностей.'),
    ('employee_status_history', false, 'История статусов сотрудников.'),
    ('employee_statuses', false, 'Справочник статусов сотрудников.'),
    ('employees', false, 'Сотрудники; персональные, парольные и финансовые поля ограничены.'),
    ('forms', false, 'Печатные формы заказов.'),
    ('forms_series', false, 'Справочник серий форм.'),
    ('materials', false, 'Материалы склада.'),
    ('materials_arrivals', false, 'Приход материалов.'),
    ('materials_inventories', false, 'Инвентаризация материалов.'),
    ('materials_writeoffs', false, 'Списания материалов.'),
    ('order_consumption_snapshots', false, 'Снимки расхода по заказам.'),
    ('order_events', false, 'История событий заказа.'),
    ('order_form_blocks', false, 'Справочник блоков формы заказа.'),
    ('order_option_defs', false, 'Дополнительные опции заказа.'),
    ('order_option_values', false, 'Значения дополнительных опций.'),
    ('order_paint_pending_writeoffs', true, 'Отложенные списания краски.'),
    ('order_paint_reservations', true, 'Брони краски заказа.'),
    ('order_paints', false, 'Краски заказа.'),
    ('order_paper_reservations', true, 'Брони бумаги заказа.'),
    ('order_predicates', false, 'Справочник предикатов заказа.'),
    ('order_shipments', true, 'Партии отгрузки; остаток вычисляется.'),
    ('orders', true, 'Заказы; подсчёты учитывают поколения.'),
    ('paints', true, 'Краски и кэш броней.'),
    ('paints_arrivals', false, 'Приходы краски.'),
    ('paints_inventories', false, 'Инвентаризации краски.'),
    ('paints_writeoffs', false, 'Списания краски.'),
    ('paper_items', false, 'Единицы бумаги.'),
    ('paper_moves', false, 'Движения бумаги.'),
    ('papers', true, 'Бумага и текущие остатки.'),
    ('papers_arrivals', false, 'Приходы бумаги.'),
    ('papers_inventories', false, 'Инвентаризации бумаги.'),
    ('papers_writeoffs', false, 'Списания бумаги.'),
    ('positions', false, 'Должности.'),
    ('prod_plan_stages', false, 'Этапы производственного плана.'),
    ('prod_plans', false, 'Производственные планы.'),
    ('prod_stage_comments', false, 'Комментарии этапов производства.'),
    ('prod_stage_history', true, 'История производственных этапов.'),
    ('product_type_configs', true, 'Версии конфигураций типа продукта.'),
    ('product_type_form_block_conditions', false, 'Условия обязательности блоков.'),
    ('product_type_form_blocks', false, 'Настройки блоков формы версии.'),
    ('product_type_stage_conditions', false, 'Условия этапов маршрута.'),
    ('product_type_stage_workplaces', false, 'Рабочие места этапов маршрута.'),
    ('product_type_stages', true, 'Версионируемые этапы маршрута.'),
    ('production_plans', false, 'Планы производства.'),
    ('production_queue_state', false, 'Состояние очереди производства.'),
    ('schema_change_log', false, 'Журнал дрейфа схемы.'),
    ('task_event_requests', false, 'Ключи идемпотентных действий этапа.'),
    ('tasks', true, 'JSONB-журнал событий; только золотые запросы для аналитики.'),
    ('warehouse_categories', false, 'Категории склада.'),
    ('warehouse_category_inventories', false, 'Инвентаризации категорий склада.'),
    ('warehouse_category_items', false, 'Позиции категорий склада.'),
    ('warehouse_category_writeoffs', false, 'Списания категорий склада.'),
    ('warehouse_deleted_records', true, 'Мягко удалённые складские записи.'),
    ('work_schedules', false, 'Графики работы.'),
    ('workplace_positions', false, 'Связь рабочих мест и должностей.'),
    ('workplace_queue_positions', false, 'Позиции задач в очередях.'),
    ('workplace_setup_history', false, 'История наладок рабочих мест.'),
    ('workplaces', false, 'Рабочие места.'),
    ('paper_stock_view', true, 'Расчётный остаток бумаги.'),
    ('v_order_plan_stages', false, 'Представление этапов заказа.'),
    ('v_orders_with_form', true, 'Заказы с формами; поколения учитываются отдельно.'),
    ('v_paints', true, 'Представление остатков краски.'),
    ('v_papers', true, 'Представление остатков бумаги.')
)
insert into public.ai_allowed_objects
  (schema_name, object_name, object_kind, allowed_operations, requires_golden_query, reason)
select 'public', object_name,
       case when object_name like 'v\_%' escape '\' or object_name like '%\_view' escape '\'
            then 'view' else 'table' end,
       array['select']::text[], requires_golden_query, reason
from allowed_tables
on conflict (schema_name, object_name, object_kind) do update set
  allowed_operations = excluded.allowed_operations,
  requires_golden_query = excluded.requires_golden_query,
  reason = excluded.reason,
  active = true,
  updated_at = now();

update public.ai_allowed_objects
set sensitive_columns = array[
      'last_name', 'first_name', 'patronymic', 'iin', 'photo_url',
      'comments', 'login', 'password', 'base_day_salary'
    ],
    financial_columns = array['base_day_salary'],
    updated_at = now()
where schema_name = 'public' and object_name = 'employees';

update public.ai_allowed_objects
set sensitive_columns = array['employee_id', 'user_id'], updated_at = now()
where schema_name = 'public'
  and object_name in ('employee_attendance', 'employee_positions', 'employee_status_history');

with allowed_functions(object_name, reason) as (
  values
    ('data_health_report', 'Базовая stable-диагностика проекта.'),
    ('find_forms', 'Поиск форм без изменения данных.'),
    ('get_order_generation_chain', 'Склейка поколений заказа.'),
    ('get_order_restart_history', 'История возобновлений заказа.'),
    ('normalize_paint_name', 'Нормализация имени краски.'),
    ('order_actual_qty_compute', 'Расчёт фактического количества заказа.'),
    ('order_actual_qty_rows', 'Источники фактического количества.'),
    ('order_pack_size', 'Размер упаковки заказа.'),
    ('order_paint_pending_debt_grams', 'Долг краски по заказу.'),
    ('order_paper_slots', 'Слоты бумаги заказа.'),
    ('order_paper_usage_state', 'Read-only состояние расхода бумаги.'),
    ('order_paper_writeoff_stage_key', 'Ключ этапа списания бумаги.'),
    ('order_stage_is_last', 'Проверка последнего этапа.'),
    ('paint_reservation_has_pending_debt', 'Проверка долга по брони краски.'),
    ('resolve_order_form', 'Разрешение ссылки на форму.'),
    ('safe_paint_id', 'Безопасное преобразование идентификатора краски.'),
    ('stage_is_packaging', 'Определение этапа упаковки.'),
    ('task_comment_millis', 'Разбор времени комментария.'),
    ('task_comments_to_array', 'Нормализация JSONB-комментариев.'),
    ('task_finish_record_is_repeat', 'Проверка повторной записи завершения.'),
    ('task_iso_utc', 'Нормализация времени задачи в UTC.'),
    ('task_json_payload', 'Разбор JSON payload задачи.'),
    ('task_open_interval_index', 'Поиск открытого интервала.'),
    ('task_order_quantity_measure', 'Расчёт единицы и ожидаемого количества.'),
    ('task_quantity_payload', 'Разбор payload количества.'),
    ('task_quantity_share_preview', 'Read-only предпросмотр долей.'),
    ('task_quantity_value', 'Разбор числового значения количества.'),
    ('validate_product_type_config', 'Read-only проверка конфигурации продукта.')
)
insert into public.ai_allowed_objects
  (schema_name, object_name, object_kind, allowed_operations, requires_golden_query, reason)
select 'public', object_name, 'function', array['execute']::text[],
       object_name in ('data_health_report', 'get_order_generation_chain', 'task_quantity_share_preview'),
       reason
from allowed_functions
on conflict (schema_name, object_name, object_kind) do update set
  allowed_operations = excluded.allowed_operations,
  requires_golden_query = excluded.requires_golden_query,
  reason = excluded.reason,
  active = true,
  updated_at = now();

-- Explicitly keep password-bearing and backup objects outside the whitelist.
delete from public.ai_allowed_objects
where schema_name = 'public'
  and object_name in (
    'employee_password_hashes', 'employees_view', 'tasks_comments_backup',
    'employee_verify_password'
  );

commit;
