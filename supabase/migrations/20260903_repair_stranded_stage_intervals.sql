-- ПРАВКА ДАННЫХ: закрыть интервалы, зависшие открытыми на завершённых этапах.
--
-- Применять ОСОЗНАННО и отдельно от схемы: правка меняет отработанное время
-- сотрудников, а значит и сдельную часть зарплаты.
--
-- ЧТО ПРОИЗОШЛО
-- Завершение этапа (complete_task_stage и путь флексопечати) никогда не
-- закрывало интервалы времени. Если сотрудник не нажал «Завершить участие»
-- сам, его интервал оставался без endTime навсегда, а аналитика считает такой
-- интервал идущим до сих пор: TaskAnalyticsMapper подставляет вместо конца
-- текущий момент. Часы росли каждый день.
--
-- Миграция 20260903_atomic_stage_writes_and_queue_slots закрывает такие
-- интервалы триггером на будущее. Этот файл чинит уже накопленное: 16
-- интервалов от 18.08 до 03.09.
--
-- ПРАВИЛО ЗАКРЫТИЯ
-- Конец = метка последнего комментария этой же задачи. После закрытия этапа
-- работать на нём было нельзя, поэтому позже последней записи интервал
-- продолжаться не мог. Это единственное правило, которое можно применить
-- автоматически ко всем строкам сразу.
--
-- ПРОВЕРИТЬ ГЛАЗАМИ перед применением (запрос ниже показывает, что получится).
-- Две строки выглядят длинными и заслуживают отдельного взгляда — там между
-- открытием интервала и последней записью прошла почти смена и больше:
--   * «С 2х листов», Айина Куанышбай, открыт 29.08 10:17 → 44.6 ч;
--   * «Фри», Ернур Жылкыбай, открыт 24.08 16:13 → 18.4 ч.
-- Если по этим двум фактическое время известно точнее — поправьте их вручную
-- после прогона, через обычную правку количества/времени.
--
--   with ev as (
--     select t.id as task_id, (c->>'timestamp')::bigint as ts,
--            (c->>'text')::jsonb as p
--       from tasks t, lateral jsonb_array_elements(t.comments) c
--      where t.status = 'completed' and c->>'type' = 'time_event'
--        and public.task_json_payload(c->>'text') is not null
--        and ((c->>'text')::jsonb ->> 'endTime') is null
--   )
--   select * from ev;

begin;

do $repair$
declare
  v_task record;
  v_comments jsonb;
  v_open int;
  v_payload jsonb;
  v_last_ms bigint;
  v_end timestamptz;
  v_guard int;
  v_closed int := 0;
  v_tasks int := 0;
begin
  for v_task in
    select t.id, t.comments
      from public.tasks t
     where t.status = 'completed'
       and public.task_open_interval_index(t.comments, null) is not null
  loop
    v_comments := public.task_comments_to_array(v_task.comments);

    select max(public.task_comment_millis(value->>'timestamp'))
      into v_last_ms
      from jsonb_array_elements(v_comments) as t(value);

    if v_last_ms is null or v_last_ms <= 0 then continue; end if;
    v_end := to_timestamp(v_last_ms / 1000.0);

    v_guard := 0;
    loop
      v_open := public.task_open_interval_index(v_comments, null);
      exit when v_open is null;
      v_payload := public.task_json_payload(v_comments->v_open->>'text')
        || jsonb_build_object('endTime', public.task_iso_utc(v_end))
        || jsonb_build_object('note', 'stage_completed_backfill');
      v_comments := jsonb_set(
        v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      v_closed := v_closed + 1;
      v_guard := v_guard + 1;
      exit when v_guard > 100;
    end loop;

    update public.tasks set comments = v_comments where id = v_task.id;
    v_tasks := v_tasks + 1;
  end loop;

  raise notice 'Закрыто интервалов: %, затронуто задач: %', v_closed, v_tasks;
end
$repair$;

commit;
