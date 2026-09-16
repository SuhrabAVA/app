begin;

insert into public.ai_golden_queries
  (code,topic,title,sql_template,parameter_schema,calculation_notes,exclusions,dependencies,known_limitations,verified_at,verified_by,verification_result,active)
values
  (
    'GQ-ORDER-STATUS-LATEST',
    'orders',
    'Статусы актуальных поколений заказов',
    $sql$with ranked as (
  select o.id,o.status,row_number() over (
    partition by coalesce(o.restart_root_order_id,o.id)
    order by o.restart_generation desc,o.created_at desc,o.id desc
  ) as generation_rank
  from public.orders o
)
select status,count(*)::bigint as order_chains
from ranked
where generation_rank=1
group by status
order by status$sql$,
    '{"type":"object","additionalProperties":false}'::jsonb,
    'Одна бизнес-цепочка считается один раз по самому новому поколению.',
    'Исторические поколения исключены из итогового счётчика.',
    '["public.orders"]'::jsonb,
    'Не показывает переходы статусов во времени.',
    now(),'codex + PostgreSQL EXPLAIN',
    '{"method":"EXPLAIN FORMAT JSON","status":"passed"}'::jsonb,true
  ),
  (
    'GQ-SHIPMENT-BALANCE',
    'shipments',
    'Отгружено и осталось по заказу',
    $sql$with target as (
  select o.id,
         coalesce(public.order_actual_qty_compute(o.id::text,null::text),0)::numeric as actual_qty
  from public.orders o
  where o.id=$1::uuid
), shipped as (
  select s.order_id,coalesce(sum(s.qty),0)::numeric as shipped_total
  from public.order_shipments s
  join target t on t.id=s.order_id
  group by s.order_id
)
select t.id,t.actual_qty,coalesce(s.shipped_total,0) as shipped_total,
       greatest(t.actual_qty-coalesce(s.shipped_total,0),0) as remaining_qty,
       (t.actual_qty<=0 or coalesce(s.shipped_total,0)>=t.actual_qty-0.01) as fully_shipped
from target t
left join shipped s on s.order_id=t.id
limit 1$sql$,
    '{"type":"object","required":["order_id"],"properties":{"order_id":{"type":"string","format":"uuid"}},"additionalProperties":false}'::jsonb,
    'Повторяет order_shipment_rules.dart: источник отгрузки — сумма order_shipments.qty; остаток не бывает отрицательным; допуск полного закрытия 0.01.',
    'orders.shipped_qty не суммируется: это последняя партия, иначе получится двойной счёт.',
    '["public.orders","public.order_shipments","public.order_actual_qty_compute"]'::jsonb,
    'Режим whole/partial хранится в пользовательском действии и этим запросом не восстанавливается.',
    now(),'codex + Dart rule review + PostgreSQL EXPLAIN',
    '{"method":"EXPLAIN FORMAT JSON","status":"passed","estimated_cost":4.87}'::jsonb,true
  ),
  (
    'GQ-PRODUCTION-OVERDUE',
    'orders',
    'Просроченные незавершённые заказы',
    $sql$select o.id,o.product_name,o.status,o.due_date,
       ((now() at time zone 'Asia/Qostanay')::date-
        (o.due_date at time zone 'Asia/Qostanay')::date)::integer as overdue_days
from public.orders o
where o.completed_at is null
  and o.status<>'completed'
  and (o.due_date at time zone 'Asia/Qostanay')::date <
      (now() at time zone 'Asia/Qostanay')::date
order by overdue_days desc,o.due_date asc
limit 200$sql$,
    '{"type":"object","additionalProperties":false}'::jsonb,
    'Повторяет production_issues.dart: сравниваются календарные дни Костаная; завершение определяется completed_at ИЛИ status=completed.',
    'Отгрузка не считается завершением производства. Для этой панели используется due_date.',
    '["public.orders","lib/modules/production/production_issues.dart"]'::jsonb,
    'Максимум 200 строк; при достижении лимита ответ обязан сообщить об усечении.',
    now(),'codex + Dart rule review + PostgreSQL EXPLAIN',
    '{"method":"EXPLAIN FORMAT JSON","status":"passed","timezone":"Asia/Qostanay"}'::jsonb,true
  ),
  (
    'GQ-ORDER-GENERATION-CHAIN',
    'orders',
    'Цепочка поколений заказа',
    $sql$select id,status,restart_generation,restarted_from_order_id,
       restart_root_order_id,created_at,completed_at
from public.get_order_generation_chain($1::text)
order by restart_generation
limit 200$sql$,
    '{"type":"object","required":["order_id"],"properties":{"order_id":{"type":"string","format":"uuid"}},"additionalProperties":false}'::jsonb,
    'Использует существующую stable-функцию проекта для восстановления всей цепочки.',
    'Не возвращает содержимое самого заказа и персональные поля.',
    '["public.get_order_generation_chain"]'::jsonb,
    'Планировщик оценивает Function Scan консервативно; фактическая цепочка обычно мала.',
    now(),'codex + PostgreSQL EXPLAIN',
    '{"method":"EXPLAIN FORMAT JSON","status":"passed"}'::jsonb,true
  ),
  (
    'GQ-DATA-HEALTH-SUMMARY',
    'data_quality',
    'Сводка встроенной диагностики',
    $sql$select code,severity,title,affected,hint
from public.data_health_report()
order by case severity when 'critical' then 1 when 'warning' then 2 else 3 end,code
limit 200$sql$,
    '{"type":"object","additionalProperties":false}'::jsonb,
    'Использует встроенную stable-диагностику проекта и возвращает только сводку.',
    'Поле sample намеренно исключено: примеры могут содержать клиентов, сотрудников и идентификаторы.',
    '["public.data_health_report"]'::jsonb,
    'Набор кодов зависит от текущей версии функции.',
    now(),'codex + PostgreSQL EXPLAIN',
    '{"method":"EXPLAIN FORMAT JSON","status":"passed","sample_excluded":true}'::jsonb,true
  )
on conflict (code) do update set
  topic=excluded.topic,
  title=excluded.title,
  sql_template=excluded.sql_template,
  parameter_schema=excluded.parameter_schema,
  calculation_notes=excluded.calculation_notes,
  exclusions=excluded.exclusions,
  dependencies=excluded.dependencies,
  known_limitations=excluded.known_limitations,
  verified_at=excluded.verified_at,
  verified_by=excluded.verified_by,
  verification_result=excluded.verification_result,
  active=excluded.active,
  updated_at=now();

commit;
