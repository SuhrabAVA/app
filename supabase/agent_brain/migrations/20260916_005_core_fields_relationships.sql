begin;

-- Correct the baseline check catalogued by migration 004. The production
-- function currently returns affected and sample, not affected_count/examples.
update public.ai_quality_checks
set sql_template = 'select code, severity, title, affected, hint, sample from public.data_health_report()',
    updated_at = now()
where code = 'DH-BASELINE';

insert into public.ai_entities
  (code, business_name, entity_kind, source_schema, source_object, description, sensitivity)
values
  ('order_paint', 'Краска заказа', 'table', 'public', 'order_paints', 'Плановая краска, привязанная к заказу.', 'internal'),
  ('paint_reservation', 'Бронь краски', 'table', 'public', 'order_paint_reservations', 'Бронь, расход и освобождение краски по заказу.', 'internal'),
  ('paint_pending_writeoff', 'Отложенное списание краски', 'table', 'public', 'order_paint_pending_writeoffs', 'Долг по списанию краски, который ещё не закрыт.', 'internal'),
  ('paper_reservation', 'Бронь бумаги', 'table', 'public', 'order_paper_reservations', 'Количество бумаги, зарезервированное для заказа.', 'internal'),
  ('product_type_stage', 'Этап версии маршрута', 'table', 'public', 'product_type_stages', 'Версионируемый этап производственного маршрута.', 'internal')
on conflict (code) do update set
  business_name = excluded.business_name,
  entity_kind = excluded.entity_kind,
  source_schema = excluded.source_schema,
  source_object = excluded.source_object,
  description = excluded.description,
  sensitivity = excluded.sensitivity,
  updated_at = now();

with field_seed(entity_code, column_name, business_name, data_type, description, unit, allowed_values, sensitivity, pitfalls, source_reference) as (
  values
    ('order','id','ID заказа','uuid','Уникальная строка поколения заказа.',null,'[]'::jsonb,'internal',array['Не считать ID бизнес-заказом без учёта цепочки поколений.'],'public.orders'),
    ('order','customer','Клиент','text','Название клиента заказа.',null,'[]'::jsonb,'personal',array[]::text[],'public.orders'),
    ('order','order_date','Дата заказа','timestamptz','Дата создания заказа.',null,'[]'::jsonb,'internal',array['Для относительных периодов использовать UTC+5.'],'public.orders'),
    ('order','due_date','Срок','timestamptz','Плановый срок заказа.',null,'[]'::jsonb,'internal',array['Не подменять promised_at.'],'public.orders'),
    ('order','promised_at','Обещанный срок','timestamptz','Отдельно зафиксированный обещанный срок.',null,'[]'::jsonb,'internal',array['Может быть NULL.'],'public.orders'),
    ('order','run_size','Плановый тираж','integer','Заказанное количество.', 'шт','[]'::jsonb,'internal',array['Не равно фактическому количеству и сумме личной выработки.'],'public.orders'),
    ('order','actual_qty','Фактическое количество','numeric','Рассчитанный или сохранённый фактический выпуск.', 'шт','[]'::jsonb,'internal',array['Предпочитать order_actual_qty_compute/rows.'],'public.orders'),
    ('order','status','Статус заказа','text','Текущее состояние поколения заказа.',null,'["draft","ready_to_start","waiting_materials","in_production","completed"]'::jsonb,'internal',array['completed не доказывает полную отгрузку.'],'public.orders'),
    ('order','shipped_qty','Кэш отгруженного количества','numeric','Сохранённое суммарное количество отгрузки.', 'шт','[]'::jsonb,'internal',array['Для проверки пересчитать сумму order_shipments.qty.'],'public.orders'),
    ('order','restarted_from_order_id','Предыдущее поколение','uuid','Непосредственный родитель возобновлённого заказа.',null,'[]'::jsonb,'internal',array['Самоссылка на orders.'],'public.orders'),
    ('order','restart_root_order_id','Корень цепочки','uuid','Первое поколение цепочки возобновлений.',null,'[]'::jsonb,'internal',array['NULL обычно означает исходное поколение.'],'public.orders'),
    ('order','restart_generation','Номер поколения','integer','Номер возобновления внутри цепочки.',null,'[]'::jsonb,'internal',array['Начинается с 0.'],'public.orders'),
    ('order','product_type_id','Тип продукта','uuid','Категория продукта заказа.',null,'[]'::jsonb,'internal',array['FK ведёт в warehouse_categories.'],'public.orders'),
    ('order','stage_config_id','Версия маршрута','uuid','Зафиксированная версия маршрута заказа.',null,'[]'::jsonb,'internal',array['Не подменять последней опубликованной версией.'],'public.orders'),
    ('task','id','ID задачи','uuid','Уникальная производственная задача.',null,'[]'::jsonb,'internal',array[]::text[],'public.tasks'),
    ('task','order_id','Заказ задачи','uuid','Заказ, для которого создан этап.',null,'[]'::jsonb,'internal',array['Логическая связь; FK в текущей схеме отсутствует.'],'public.tasks'),
    ('task','stage_id','ID этапа','text','Идентификатор этапа в задаче.',null,'[]'::jsonb,'internal',array['Тип text; не соединять с uuid без подтверждённого преобразования.'],'public.tasks'),
    ('task','status','Статус задачи','text','Текущее состояние производственной задачи.',null,'["waiting","inProgress","paused","problem","completed"]'::jsonb,'internal',array[]::text[],'public.tasks'),
    ('task','spent_seconds','Кэш времени','integer','Сохранённая длительность задачи.', 'сек','[]'::jsonb,'internal',array['Для аналитики времени использовать золотой запрос по событиям.'],'public.tasks'),
    ('task','started_at','Начало','bigint','Unix-время начала.', 'мс','[]'::jsonb,'internal',array['Не timestamptz; нормализовать через task_iso_utc.'],'public.tasks'),
    ('task','completed_at','Завершение','bigint','Unix-время завершения.', 'мс','[]'::jsonb,'internal',array['Не timestamptz.'],'public.tasks'),
    ('task','assignees','Исполнители','text[]','Снимок назначенных сотрудников.',null,'[]'::jsonb,'personal',array['История смен исполнителей хранится также в comments.'],'public.tasks'),
    ('task','comments','Журнал событий','jsonb','События времени, количества, наладки и смен.',null,'[]'::jsonb,'internal',array['Не агрегировать напрямую; нужен золотой запрос.'],'public.tasks'),
    ('task','captured_by_workplace_id','Рабочее место захвата','text','Рабочее место, взявшее задачу.',null,'[]'::jsonb,'internal',array['Логическая связь с workplaces.id.'],'public.tasks'),
    ('task','captured_by_user_id','Пользователь захвата','text','Сотрудник, взявший задачу.',null,'[]'::jsonb,'personal',array['Логическая связь с employees.id.'],'public.tasks'),
    ('workplace','id','ID рабочего места','text','Стабильный идентификатор рабочего места.',null,'[]'::jsonb,'internal',array[]::text[],'public.workplaces'),
    ('workplace','name','Название','text','Название рабочего места.',null,'[]'::jsonb,'internal',array[]::text[],'public.workplaces'),
    ('workplace','execution_mode','Режим выполнения','text','Совместное или раздельное выполнение.',null,'[]'::jsonb,'internal',array['Влияет на распределение личной выработки.'],'public.workplaces'),
    ('workplace','split_quantity_by_time','Делить по времени','boolean','Признак распределения количества по времени.',null,'[]'::jsonb,'internal',array['Учитывать вместе с quantity_share.'],'public.workplaces'),
    ('employee','id','ID сотрудника','text','Идентификатор сотрудника.',null,'[]'::jsonb,'personal',array[]::text[],'public.employees'),
    ('employee','is_fired','Уволен','boolean','Признак увольнения сотрудника.',null,'[]'::jsonb,'personal',array['Не исключать автоматически из исторической аналитики.'],'public.employees'),
    ('employee','login','Логин','text','Учётное имя.',null,'[]'::jsonb,'secret',array['Не выдавать в обычных ответах.'],'public.employees'),
    ('employee','password','Пароль','text','Устаревшее парольное поле.',null,'[]'::jsonb,'secret',array['Никогда не выбирать и не возвращать.'],'public.employees'),
    ('employee','iin','ИИН','text','Персональный идентификатор.',null,'[]'::jsonb,'secret',array['Никогда не возвращать без специального права.'],'public.employees'),
    ('employee','base_day_salary','Базовая дневная ставка','numeric','Финансовая ставка сотрудника.',null,'[]'::jsonb,'financial',array['Доступ только финансовой роли.'],'public.employees'),
    ('shipment','order_id','Заказ','uuid','Заказ партии отгрузки.',null,'[]'::jsonb,'internal',array[]::text[],'public.order_shipments'),
    ('shipment','qty','Количество партии','numeric','Количество в одной отгрузке.', 'шт','[]'::jsonb,'internal',array['Остаток = план/факт минус сумма партий по правилу приложения.'],'public.order_shipments'),
    ('shipment','shipped_at','Время отгрузки','timestamptz','Серверное время партии.',null,'[]'::jsonb,'internal',array[]::text[],'public.order_shipments'),
    ('paint','quantity','Остаток краски','numeric','Текущий складской остаток.',null,'[]'::jsonb,'internal',array['Сопоставлять с unit.'],'public.paints'),
    ('paint','reserved_qty','Кэш брони','double precision','Сохранённая сумма активных броней.',null,'[]'::jsonb,'internal',array['Может расходиться с суммой броней; проверять health report.'],'public.paints'),
    ('paint_reservation','reserved_qty','Забронировано','double precision','Исходно зарезервированное количество.', 'г','[]'::jsonb,'internal',array[]::text[],'public.order_paint_reservations'),
    ('paint_reservation','used_qty','Использовано','double precision','Количество, закрытое расходом.', 'г','[]'::jsonb,'internal',array[]::text[],'public.order_paint_reservations'),
    ('paint_reservation','released_qty','Освобождено','double precision','Количество, возвращённое из брони.', 'г','[]'::jsonb,'internal',array['Доступный остаток брони вычисляется, а не читается одним полем.'],'public.order_paint_reservations'),
    ('paint_pending_writeoff','status','Статус долга','text','Состояние отложенного списания.',null,'["pending","written_off"]'::jsonb,'internal',array['Проверять фактические значения при дрейфе.'],'public.order_paint_pending_writeoffs'),
    ('paint_pending_writeoff','actual_used_amount','Фактический расход','double precision','Количество краски к списанию.', 'г','[]'::jsonb,'internal',array['NULL не считать нулём без явного правила.'],'public.order_paint_pending_writeoffs'),
    ('paper','quantity','Остаток бумаги','numeric','Текущий складской остаток.',null,'[]'::jsonb,'internal',array['Сопоставлять с unit.'],'public.papers'),
    ('paper_reservation','qty','Бронь бумаги','double precision','Количество бумаги для заказа.',null,'[]'::jsonb,'internal',array['Не может быть отрицательным.'],'public.order_paper_reservations'),
    ('product_type_config','version','Версия','integer','Номер версии маршрута типа продукта.',null,'[]'::jsonb,'internal',array['Сравнивать только внутри одного product_type_id.'],'public.product_type_configs'),
    ('product_type_config','status','Статус версии','text','Жизненный цикл конфигурации.',null,'["draft","published","archived"]'::jsonb,'internal',array['Заказ использует stage_config_id, а не всегда текущую published.'],'public.product_type_configs'),
    ('product_type_stage','stage_group_key','Группа этапа','text','Стабильный логический ключ этапа.',null,'[]'::jsonb,'internal',array[]::text[],'public.product_type_stages'),
    ('product_type_stage','selection_mode','Режим выбора','text','Правило выбора вариантов этапа.',null,'[]'::jsonb,'internal',array['Switchable требует минимум два варианта.'],'public.product_type_stages'),
    ('product_type_stage','execution_mode','Режим исполнения','text','Последовательный или параллельный этап.',null,'[]'::jsonb,'internal',array['Для parallel нужна корректная ссылка parallel_with_stage_id.'],'public.product_type_stages')
)
insert into public.ai_fields
  (entity_id, column_name, business_name, data_type, description, unit, allowed_values, sensitivity, pitfalls, source_reference)
select e.id, f.column_name, f.business_name, f.data_type, f.description, f.unit,
       f.allowed_values, f.sensitivity, f.pitfalls, f.source_reference
from field_seed f
join public.ai_entities e on e.code = f.entity_code
on conflict (entity_id, column_name) do update set
  business_name = excluded.business_name,
  data_type = excluded.data_type,
  description = excluded.description,
  unit = excluded.unit,
  allowed_values = excluded.allowed_values,
  sensitivity = excluded.sensitivity,
  pitfalls = excluded.pitfalls,
  source_reference = excluded.source_reference,
  updated_at = now();

with relation_seed(code, from_code, to_code, relationship_kind, cardinality, join_expression, description, confirmed_by_human) as (
  values
    ('REL-TASK-ORDER','task','order','logical','many_to_one','tasks.order_id = orders.id','Связь существует по данным и коду, но FK в текущей схеме отсутствует.',true),
    ('REL-TASK-WORKPLACE','task','workplace','logical','many_to_one','tasks.captured_by_workplace_id = workplaces.id','Рабочее место захвата задачи.',true),
    ('REL-TASK-EMPLOYEE','task','employee','logical','many_to_one','tasks.captured_by_user_id = employees.id','Сотрудник захвата; история участников также находится в JSONB.',true),
    ('REL-SHIPMENT-ORDER','shipment','order','foreign_key','many_to_one','order_shipments.order_id = orders.id','Партии отгрузки заказа.',true),
    ('REL-ORDER-PARENT','order','order','foreign_key','many_to_one','orders.restarted_from_order_id = orders.id','Предыдущее поколение возобновлённого заказа.',true),
    ('REL-ORDER-ROOT','order','order','foreign_key','many_to_one','orders.restart_root_order_id = orders.id','Корень цепочки поколений.',true),
    ('REL-ORDER-CONFIG','order','product_type_config','foreign_key','many_to_one','orders.stage_config_id = product_type_configs.id','Версия маршрута, зафиксированная для заказа.',true),
    ('REL-CONFIG-STAGE','product_type_stage','product_type_config','foreign_key','many_to_one','product_type_stages.config_id = product_type_configs.id','Этапы конкретной версии маршрута.',true),
    ('REL-PAINT-RESERVATION','paint_reservation','paint','foreign_key','many_to_one','order_paint_reservations.paint_id = paints.id','Бронь складской краски.',true),
    ('REL-PAINT-DEBT','paint_pending_writeoff','paint','foreign_key','many_to_one','order_paint_pending_writeoffs.paint_id = paints.id','Отложенное списание складской краски.',true),
    ('REL-PAPER-RESERVATION-ORDER','paper_reservation','order','foreign_key','many_to_one','order_paper_reservations.order_id = orders.id','Бронь бумаги заказа.',true),
    ('REL-PAPER-RESERVATION-PAPER','paper_reservation','paper','foreign_key','many_to_one','order_paper_reservations.paper_id = papers.id','Бронь складской бумаги.',true)
)
insert into public.ai_relationships
  (code, from_entity_id, to_entity_id, relationship_kind, cardinality, join_expression, description, confirmed_by_human)
select r.code, fe.id, te.id, r.relationship_kind, r.cardinality, r.join_expression, r.description, r.confirmed_by_human
from relation_seed r
join public.ai_entities fe on fe.code = r.from_code
join public.ai_entities te on te.code = r.to_code
on conflict (code) do update set
  from_entity_id = excluded.from_entity_id,
  to_entity_id = excluded.to_entity_id,
  relationship_kind = excluded.relationship_kind,
  cardinality = excluded.cardinality,
  join_expression = excluded.join_expression,
  description = excluded.description,
  confirmed_by_human = excluded.confirmed_by_human,
  updated_at = now();

insert into public.ai_status_dictionary
  (entity_code, field_name, status_value, display_name, description, terminal, aliases, source_reference, confirmed_by_human)
values
  ('order','status','draft','Черновик','Заказ ещё редактируется.',false,array['черновик'],'public.orders + фактические значения',true),
  ('order','status','ready_to_start','Готов к запуску','Заказ готов к началу производства.',false,array['готов'],'public.orders + фактические значения',true),
  ('order','status','waiting_materials','Ожидает материалы','Запуск блокируют материалы.',false,array['ждёт материалы'],'public.orders + фактические значения',true),
  ('order','status','in_production','В производстве','Заказ находится в производстве.',false,array['производство'],'public.orders + фактические значения',true),
  ('order','status','completed','Завершён','Производственный цикл завершён.',true,array['готов','завершен'],'public.orders + фактические значения',true),
  ('task','status','waiting','Ожидает','Задача ожидает начала.',false,array['ожидание'],'public.tasks + фактические значения',true),
  ('task','status','inProgress','В работе','Задача выполняется.',false,array['в процессе','работает'],'public.tasks + фактические значения',true),
  ('task','status','paused','На паузе','Работа временно остановлена.',false,array['пауза'],'public.tasks + фактические значения',true),
  ('task','status','problem','Проблема','Задача заблокирована проблемой.',false,array['ошибка','блокировка'],'public.tasks + фактические значения',true),
  ('task','status','completed','Завершена','Задача завершена.',true,array['готово'],'public.tasks + фактические значения',true),
  ('product_type_config','status','draft','Черновик','Редактируемая версия маршрута.',false,array['черновик'],'public.product_type_configs',true),
  ('product_type_config','status','published','Опубликована','Активная опубликованная версия.',false,array['активная'],'public.product_type_configs',true),
  ('product_type_config','status','archived','Архив','Неактивная историческая версия.',true,array['архивная'],'public.product_type_configs',true)
on conflict (entity_code, field_name, status_value) do update set
  display_name = excluded.display_name,
  description = excluded.description,
  terminal = excluded.terminal,
  aliases = excluded.aliases,
  source_reference = excluded.source_reference,
  confirmed_by_human = excluded.confirmed_by_human,
  updated_at = now();

commit;
