-- ============================================================================
-- Целостность данных, шаг 2: интервалы времени завершённых этапов (2026-09-14)
--
-- Что чинит
-- ---------
-- 1. На проде нет триггера tasks_close_intervals_on_complete. Функция есть,
--    триггера нет: миграция 20260903 применялась не целиком (в журнале
--    миграций её нет вовсе). Функции завершения этапа интервалы сами не
--    закрывают — рассчитывали на триггер. На 14.09 у 18 завершённых этапов
--    интервал открыт, и время «тикает» до сих пор: неверные часы в
--    аналитике и неверная доля при любом пересчёте.
--
-- 2. Интервал открывался на УЖЕ завершённом этапе. Планшет без связи
--    складывает «Старт» в очередь повторов и досылает его через часы — после
--    того, как этап закрыли (Бабинорезка, задача c2808413: этап закрыт 07:40,
--    «старт» доехал в 15:02). Сервер это принимал.
--
-- 3. tasks.completed_at заполнен у 91 из 947 завершённых задач:
--    complete_task_stage ставит status = 'completed' раньше, чем
--    advance_order_after_task_completion ставит completed_at, а та обновляет
--    только незавершённые строки. Клиент тогда берёт время завершения из
--    комментариев или updated_at — а updated_at сдвигает любая правка строки,
--    в том числе пересчёт долей.
--
-- Что делает миграция
-- -------------------
-- 1. completed_at: замораживает у завершённых задач ровно то значение, которое
--    клиент (_taskCompletionMillis) и так вычисляет сейчас. Поведение не
--    меняется, но дальнейшие правки строки его больше не сдвигают.
-- 2. Закрывает открытые интервалы завершённых задач моментом завершения;
--    открытый уже после завершения — нулевой длины.
-- 3. Триггер: при переходе в completed закрывает интервалы и ставит
--    completed_at.
-- 4. task_apply_stage_events отказывает в открытии интервала на завершённом
--    этапе. Отказ (не обрыв связи) очередь повторов клиента не повторяет.
-- ============================================================================

begin;

-- ─── 1. completed_at завершённых задач ───────────────────────────────────────

update public.tasks t
   set completed_at = coalesce(
         (
           select max(public.task_comment_millis(c->>'timestamp'))
             from jsonb_array_elements(public.task_comments_to_array(t.comments)) c
            -- тот же список, что в TaskProvider._taskCompletionMillis
            where c->>'type' in ('user_done', 'quantity_done',
                                 'quantity_team_total', 'finish_note')
         ),
         floor(extract(epoch from t.updated_at) * 1000)::bigint
       )
 where t.status = 'completed'
   and t.completed_at is null;

-- ─── 2. Открытые интервалы завершённых задач ────────────────────────────────

do $repair$
declare
  v_task record;
  v_comments jsonb;
  v_open int;
  v_payload jsonb;
  v_start timestamptz;
  v_end timestamptz;
  v_guard int;
begin
  for v_task in
    select t.id, t.comments, t.completed_at
      from public.tasks t
     where t.status = 'completed'
       and exists (
         select 1
           from jsonb_array_elements(public.task_comments_to_array(t.comments)) c
          -- то же определение «открыт», что в task_open_interval_index
          where c->>'type' = 'time_event'
            and public.task_json_payload(c->>'text') is not null
            and (public.task_json_payload(c->>'text')->>'endTime') is null
       )
     for update
  loop
    v_comments := public.task_comments_to_array(v_task.comments);
    v_guard := 0;
    loop
      v_open := public.task_open_interval_index(v_comments, null);
      exit when v_open is null;
      v_payload := public.task_json_payload(v_comments->v_open->>'text');
      v_start := (v_payload->>'startTime')::timestamptz;
      v_end := timestamptz 'epoch' + v_task.completed_at * interval '1 millisecond';
      v_payload := v_payload
        || jsonb_build_object(
             'endTime', public.task_iso_utc(greatest(v_start, v_end)),
             'note', case when v_start > v_end
                          then 'opened_after_completion'
                          else 'stage_completed' end,
             'repaired', '20260914');
      v_comments := jsonb_set(
        v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      v_guard := v_guard + 1;
      exit when v_guard > 500;
    end loop;

    update public.tasks set comments = v_comments where id = v_task.id;
  end loop;
end
$repair$;

-- ─── 3. Триггер завершения ──────────────────────────────────────────────────

create or replace function public.tasks_close_intervals_on_complete()
returns trigger
language plpgsql
as $function$
declare
  v_comments jsonb;
  v_open int;
  v_payload jsonb;
  v_now timestamptz := clock_timestamp();
  v_guard int := 0;
begin
  if new.status <> 'completed' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'completed' then return new; end if;

  v_comments := public.task_comments_to_array(new.comments);
  loop
    v_open := public.task_open_interval_index(v_comments, null);
    exit when v_open is null;
    v_payload := public.task_json_payload(v_comments->v_open->>'text')
      || jsonb_build_object('endTime', public.task_iso_utc(v_now))
      || jsonb_build_object('note', 'stage_completed');
    v_comments := jsonb_set(
      v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
    v_guard := v_guard + 1;
    exit when v_guard > 500;
  end loop;
  new.comments := v_comments;

  -- Время завершения ставится здесь, одним местом для всех путей: RPC,
  -- пропуск этапа, ручная смена статуса.
  if new.completed_at is null then
    new.completed_at := floor(extract(epoch from v_now) * 1000)::bigint;
  end if;

  return new;
end
$function$;

drop trigger if exists tasks_close_intervals_on_complete on public.tasks;
create trigger tasks_close_intervals_on_complete
  before insert or update of status on public.tasks
  for each row
  execute function public.tasks_close_intervals_on_complete();

comment on function public.tasks_close_intervals_on_complete() is
  'При переводе этапа в completed закрывает все открытые интервалы времени и '
  'ставит completed_at. Без него интервал остаётся открытым навсегда, а '
  'аналитика и расчёт долей считают его идущим до сих пор.';

-- ─── 4. Запрет открывать интервал на завершённом этапе ──────────────────────

do $patch$
declare
  v_sig constant regprocedure :=
    'public.task_apply_stage_events(text,jsonb,text,uuid)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_anchor constant text := 'v_result := public.task_apply_ops(';
  v_guard constant text :=
    'if v_task.status = ''completed'' and jsonb_typeof(p_ops) = ''array'' '
    || 'and exists (select 1 from jsonb_array_elements(p_ops) o '
    || 'where o->>''op'' = ''open_interval'') then '
    || 'raise exception using message = ''Этап уже завершён — начать или '
    || 'продолжить работу на нём нельзя. Обновите экран.'', '
    || 'errcode = ''check_violation''; '
    || 'end if; ';
  v_count int;
begin
  if position('Этап уже завершён — начать или' in v_def) > 0 then
    raise notice 'task_apply_stage_events уже пропатчена — пропуск';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, '')))
             / length(v_anchor);
  if v_count <> 1 then
    raise exception 'Шаблон task_apply_ops найден % раз(а) вместо 1 — '
      'функция изменилась, миграцию нужно пересобрать', v_count;
  end if;

  v_def := replace(v_def, v_anchor, v_guard || v_anchor);
  execute v_def;
end
$patch$;

commit;
