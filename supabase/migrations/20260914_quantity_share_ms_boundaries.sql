-- Фантомная доля у сдавшего смену: границы отрезка в мс, интервалы в мкс.
--
-- ЖИВОЙ СЛУЧАЙ
-- Лостовец, Флексопечать (задача 4a3a84e4): Медет сдал смену с 14 500 м, Равиль
-- закончил этап с 550 м — а Медет получил ещё и 550. В его доле за второй
-- отрезок записано `seconds: 0.000154`.
--
-- ПРИЧИНА
-- `task_apply_ops` закрывает интервал меткой `endTime = task_iso_utc(v_now)` —
-- с МИКРОсекундами, а запись тиража на той же пересмене получает
-- `timestamp = floor(v_now в мс)`. `task_quantity_share_preview` режет отрезки
-- по этой метке, поэтому хвост 0–999 мкс интервала сдавшего смену попадает в
-- СЛЕДУЮЩИЙ отрезок, и `secs > 0` делает его участником. На рабочих местах
-- без деления по времени (`split_quantity_by_time = false`: Флексопечать,
-- Бабинорезка, Листорезка, Автоматы…) участнику пишется ПОЛНОЕ количество
-- отрезка. На 14.09 таких долей 23, крупнейшая — 50 740.
--
-- ЧТО МЕНЯЕТСЯ
--   1. Границы интервалов приводятся к миллисекундам — к той же точности,
--      что и границы отрезков. Хвост в микросекунды исчезает по построению.
--   2. Участником отрезка считается тот, кто отработал в нём не меньше
--      секунды (`c_min_seconds`). Страхует от любой другой рассинхронизации
--      меток в пределах секунды: сдавшего смену «рабочим» нового отрезка это
--      не сделает. Клиент (`stage_participant_output.dart`) держит тот же
--      порог, иначе карточка до завершения этапа показывала бы другое.
--   3. Граница отрезка считается целочисленно (эпоха + N мс), а не через
--      `to_timestamp(double)`.
-- Остальное тело — действующее определение из базы без изменений.
--
-- ПЕРЕСЧЁТ
-- `recompute_task_quantity_shares` — только по завершённым задачам, где есть
-- машинная доля с 0 < seconds < 1. Функция идемпотентна и сохраняет ручные
-- доли и правки техлида. Незавершённые задачи пересчитаются сами при
-- завершении этапа. Факт заказа (`orders.actual_qty`) доли не трогают.

begin;

do $guard$
declare
  v_def text := pg_get_functiondef('public.task_quantity_share_preview(text)'::regprocedure);
begin
  if md5(v_def) <> '48fbc4cb4ed66d2ceae0d6403331076a'
     and v_def not ilike '%c_min_seconds%' then
    raise exception
      'task_quantity_share_preview изменилась после 14.09.2026 — миграция '
      'написана под другое тело. Ничего не изменено.';
  end if;
end
$guard$;

create or replace function public.task_quantity_share_preview(p_task_id text)
returns table(employee_id text, role text, segment_end timestamp with time zone, seconds numeric, raw_share numeric)
language plpgsql
stable
as $function$
declare
  -- Меньше секунды в отрезке — не участие, а рассинхрон меток (20260914).
  c_min_seconds constant numeric := 1;
  v_task tasks%rowtype;
  v_comments jsonb;
  v_assignees text[];
  v_owner text;
  v_helpers text[];
  v_split boolean;
  v_workplace text;
  v_now timestamptz := date_trunc('milliseconds', now());
  v_prev timestamptz := '-infinity'::timestamptz;
  v_seg record;
begin
  select * into v_task from public.tasks where id::text = p_task_id;
  if not found then return; end if;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);
  v_assignees := coalesce(v_task.assignees, array[]::text[]);
  v_owner := coalesce(v_assignees[1], '');

  -- Помощник — автор «joined», не совпадающий с основным исполнителем. То же
  -- правило действует в аналитике и в расчёте факта заказа; разъехавшись, они
  -- дали бы разные ответы на вопрос «кто здесь помощник».
  select coalesce(array_agg(distinct j.uid), array[]::text[])
    into v_helpers
    from (
      select trim(c->>'userId') as uid
        from jsonb_array_elements(v_comments) c
       where c->>'type' = 'joined'
    ) j
   where j.uid <> '' and j.uid <> v_owner;

  v_workplace := coalesce(
    nullif(trim(coalesce(v_task.captured_by_workplace_id::text, '')), ''),
    v_task.stage_id::text
  );
  select w.split_quantity_by_time into v_split
    from public.workplaces w
   where w.id::text = v_workplace;
  -- Рабочее место не найдено — делим по времени: это поведение по умолчанию
  -- для всех РМ, кроме явно перечисленных станков.
  v_split := coalesce(v_split, true);

  for v_seg in
    select m.seg_end, m.qty, m.author
      from (
        -- Метка записи — целые миллисекунды; граница считается без плавающей
        -- точки, чтобы сравнение с интервалами было точным.
        select timestamptz 'epoch'
                 + public.task_comment_millis(c->>'timestamp')
                   * interval '1 millisecond' as seg_end,
               public.task_quantity_value(c->>'text') as qty,
               coalesce(trim(c->>'userId'), '') as author
          from jsonb_array_elements(v_comments) c
         where c->>'type' = 'quantity_stage_total'
      ) m
     where m.qty > 0
     order by m.seg_end
  loop
    return query
    with worked as (
      select
        trim(p.ev->>'subjectUserId') as uid,
        sum(
          greatest(
            0::numeric,
            extract(epoch from (
              least(
                -- Интервалы пишутся с микросекундами, отрезки — с
                -- миллисекундами. Без приведения хвост интервала сдавшего
                -- смену попадал в следующий отрезок.
                date_trunc('milliseconds',
                  coalesce(nullif(p.ev->>'endTime', '')::timestamptz, v_now)),
                v_seg.seg_end
              )
              - greatest(
                  date_trunc('milliseconds', (p.ev->>'startTime')::timestamptz),
                  v_prev)
            ))::numeric
          )
        ) as secs
      from jsonb_array_elements(v_comments) c
      cross join lateral (
        select public.task_quantity_payload(c->>'text') as ev
      ) p
      where c->>'type' = 'time_event'
        and p.ev is not null
        and p.ev->>'type' = 'production'
        and coalesce(trim(p.ev->>'subjectUserId'), '') <> ''
        and coalesce(p.ev->>'startTime', '') <> ''
      group by 1
    ),
    positive as (
      select w.uid, w.secs from worked w where w.secs >= c_min_seconds
    ),
    participants as (
      select p.uid, p.secs from positive p
      union all
      -- T_total = 0: в отрезке никто не отработал ни секунды — станок стоял на
      -- пересмене или «проблеме», а тираж ввели уже после остановки. Делить не
      -- на кого, но и отдавать assignees нельзя: это ТЕКУЩИЕ исполнители, а
      -- смену мог сдавать другой человек. Засчитываем автору записи.
      select v_seg.author, 0::numeric
       where not exists (select 1 from positive)
         and v_seg.author <> ''
      union all
      -- Автор записи неизвестен (старый формат) — прежнее правило: поровну
      -- между исполнителями задачи.
      select a.uid, 0::numeric
        from unnest(v_assignees) as a(uid)
       where not exists (select 1 from positive)
         and v_seg.author = ''
         and coalesce(trim(a.uid), '') <> ''
    ),
    total as (
      select coalesce(sum(pt.secs), 0) as secs,
             greatest(count(*), 1) as head_count
        from participants pt
    )
    select
      pt.uid,
      case
        when pt.uid = v_owner then 'owner'
        when pt.uid = any(v_helpers) then 'helper'
        else 'executor'
      end,
      v_seg.seg_end,
      pt.secs,
      case
        -- Станок один на бригаду: вклад по часам не измеряется, тираж делает
        -- машина. Каждому пишется полное количество.
        when not v_split then v_seg.qty::numeric
        when t.secs > 0 then v_seg.qty::numeric * pt.secs / t.secs
        else v_seg.qty::numeric / t.head_count
      end
    from participants pt
    cross join total t;

    v_prev := v_seg.seg_end;
  end loop;

  return;
end
$function$;

-- Пересчёт задач с фантомными долями.
do $recompute$
declare
  v_task_id text;
  v_tasks int := 0;
begin
  for v_task_id in
    select distinct t.id::text
      from public.tasks t
     cross join lateral jsonb_array_elements(
             public.task_comments_to_array(t.comments::jsonb)) c
     where t.status = 'completed'
       and c->>'type' = 'quantity_share'
       and public.task_quantity_payload(c->>'text')->>'generated' = 'true'
       and (public.task_quantity_payload(c->>'text')->>'seconds')::numeric > 0
       and (public.task_quantity_payload(c->>'text')->>'seconds')::numeric < 1
  loop
    perform public.recompute_task_quantity_shares(v_task_id);
    v_tasks := v_tasks + 1;
  end loop;

  raise notice 'Пересчитано задач: %', v_tasks;
end
$recompute$;

commit;

-- Проверка после применения. Ожидаемо: «фантомных долей» = 0 (у завершённых).
select
  count(*) filter (where t.status = 'completed') as "фантомных долей у завершённых",
  count(*) filter (where t.status <> 'completed') as "у незавершённых (пересчитаются при завершении)"
from public.tasks t
cross join lateral jsonb_array_elements(public.task_comments_to_array(t.comments::jsonb)) c
where c->>'type' = 'quantity_share'
  and public.task_quantity_payload(c->>'text')->>'generated' = 'true'
  and (public.task_quantity_payload(c->>'text')->>'seconds')::numeric > 0
  and (public.task_quantity_payload(c->>'text')->>'seconds')::numeric < 1;
