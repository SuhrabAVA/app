-- ============================================================================
-- Проверка распределения количества по отработанному времени.
--
-- Сценарии A–H и J из ТЗ прогоняются на СИНТЕТИЧЕСКОЙ задаче через настоящую
-- функцию public.task_quantity_share_preview — то есть проверяется тот самый
-- код, который считает зарплату, а не его пересказ.
--
-- БЕЗОПАСНОСТЬ. Скрипт НИЧЕГО не оставляет в базе: он заканчивается
-- намеренным `raise exception`, а исключение откатывает всю транзакцию вместе
-- со вставленной задачей. Отчёт приходит В ТЕКСТЕ ЭТОГО ИСКЛЮЧЕНИЯ — красная
-- плашка «ERROR» здесь ожидаема и означает, что проверка отработала.
-- Ищите в ней строку ИТОГ.
--
-- Требуется: применённые 20260821_quantity_share_by_time.sql и
-- 20260821_quantity_share_rpc.sql. Третья миграция не нужна.
-- ============================================================================

do $verify$
declare
  v_base timestamptz := '2026-08-20 08:00:00+00';
  -- Без говорящего префикса: tasks.id — колонка типа uuid, и 'qs-selftest-…'
  -- в неё не приводится. Задача всё равно живёт до отката и наружу не выходит.
  v_task_id text := gen_random_uuid()::text;
  v_order_id text;
  v_wp_id text;
  v_scenarios jsonb;
  v_case jsonb;
  v_iv jsonb;
  v_seg jsonb;
  v_comments jsonb;
  v_assignees text[];
  v_expect jsonb;
  v_uid text;
  v_actual numeric;
  v_want numeric;
  v_line text;
  v_report text := '';
  v_failures int := 0;
  v_checks int := 0;
  v_idx int;
begin
  -- Берём существующие заказ и рабочее место: у tasks есть внешние ключи, и
  -- выдуманные id их не пройдут.
  select id::text into v_order_id from public.orders limit 1;
  select id::text into v_wp_id from public.workplaces limit 1;
  if v_order_id is null or v_wp_id is null then
    raise exception 'Нужен хотя бы один заказ и одно рабочее место для проверки.';
  end if;

  -- ── Сценарии ──────────────────────────────────────────────────────────────
  -- segments: end_h — конец сегмента в часах от базы, qty — тираж сегмента.
  -- intervals: from_h/to_h — интервал участника; type по умолчанию production.
  -- expect: ожидаемая СЫРАЯ доля (до единственного округления вверх).
  v_scenarios := $json$[
    {
      "name": "A. шестеро по часу, тираж 30000",
      "split": true,
      "assignees": ["own","h1","h2","h3","h4","h5"],
      "segments": [{"end_h": 1, "qty": 30000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":1},
        {"uid":"h1","from_h":0,"to_h":1},
        {"uid":"h2","from_h":0,"to_h":1},
        {"uid":"h3","from_h":0,"to_h":1},
        {"uid":"h4","from_h":0,"to_h":1},
        {"uid":"h5","from_h":0,"to_h":1}
      ],
      "expect": {"own":5000,"h1":5000,"h2":5000,"h3":5000,"h4":5000,"h5":5000}
    },
    {
      "name": "B. один ушёл через 2ч из 5 — знаменатель 27ч, не 30",
      "split": true,
      "assignees": ["own","h1","h2","h3","h4","h5"],
      "segments": [{"end_h": 5, "qty": 27000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":5},
        {"uid":"h1","from_h":0,"to_h":5},
        {"uid":"h2","from_h":0,"to_h":5},
        {"uid":"h3","from_h":0,"to_h":5},
        {"uid":"h4","from_h":0,"to_h":5},
        {"uid":"h5","from_h":0,"to_h":2}
      ],
      "expect": {"own":5000,"h1":5000,"h2":5000,"h3":5000,"h4":5000,"h5":2000}
    },
    {
      "name": "C. замена: A ушёл на 2-м часу, B пришёл вместо него",
      "split": true,
      "assignees": ["own","h1","h2","h3","ha","hb"],
      "segments": [{"end_h": 5, "qty": 25000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":5},
        {"uid":"h1","from_h":0,"to_h":5},
        {"uid":"h2","from_h":0,"to_h":5},
        {"uid":"h3","from_h":0,"to_h":5},
        {"uid":"ha","from_h":0,"to_h":2},
        {"uid":"hb","from_h":2,"to_h":5}
      ],
      "expect": {"own":5000,"h1":5000,"h2":5000,"h3":5000,"ha":2000,"hb":3000}
    },
    {
      "name": "D. помощник добавлен в последний час — ему час, не пять",
      "split": true,
      "assignees": ["own","h1"],
      "segments": [{"end_h": 5, "qty": 6000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":5},
        {"uid":"h1","from_h":4,"to_h":5}
      ],
      "expect": {"own":5000,"h1":1000}
    },
    {
      "name": "E. работал только владелец — весь тираж ему",
      "split": true,
      "assignees": ["own"],
      "segments": [{"end_h": 3, "qty": 1000}],
      "intervals": [{"uid":"own","from_h":0,"to_h":3}],
      "expect": {"own":1000}
    },
    {
      "name": "F. пересмена: два сегмента с разными составами",
      "split": true,
      "assignees": ["own","h1","h2"],
      "segments": [{"end_h": 2, "qty": 4000}, {"end_h": 4, "qty": 4000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":4},
        {"uid":"h1","from_h":0,"to_h":2},
        {"uid":"h2","from_h":2,"to_h":4}
      ],
      "expect": {"own":4000,"h1":2000,"h2":2000}
    },
    {
      "name": "G. пауза 30 мин вычтена у всех, кто был в группе",
      "split": true,
      "assignees": ["own","h1"],
      "segments": [{"end_h": 4, "qty": 7000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":2},
        {"uid":"own","from_h":2,"to_h":2.5,"type":"pause"},
        {"uid":"own","from_h":2.5,"to_h":4},
        {"uid":"h1","from_h":0,"to_h":2},
        {"uid":"h1","from_h":2,"to_h":2.5,"type":"pause"},
        {"uid":"h1","from_h":2.5,"to_h":4}
      ],
      "expect": {"own":3500,"h1":3500}
    },
    {
      "name": "G2. приладка в долю не входит (оплачивается отдельно)",
      "split": true,
      "assignees": ["own","h1"],
      "segments": [{"end_h": 4, "qty": 4000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":2,"type":"setup"},
        {"uid":"own","from_h":2,"to_h":4},
        {"uid":"h1","from_h":2,"to_h":4}
      ],
      "expect": {"own":2000,"h1":2000}
    },
    {
      "name": "H. T_total = 0 — делим поровну, не падаем",
      "split": true,
      "assignees": ["own","h1"],
      "segments": [{"end_h": 1, "qty": 1000}],
      "intervals": [],
      "expect": {"own":500,"h1":500}
    },
    {
      "name": "J. станок без деления — каждому полный тираж",
      "split": false,
      "assignees": ["own","h1","h2"],
      "segments": [{"end_h": 5, "qty": 1000}],
      "intervals": [
        {"uid":"own","from_h":0,"to_h":5},
        {"uid":"h1","from_h":0,"to_h":1},
        {"uid":"h2","from_h":4,"to_h":5}
      ],
      "expect": {"own":1000,"h1":1000,"h2":1000}
    }
  ]$json$::jsonb;

  for v_idx in 0 .. jsonb_array_length(v_scenarios) - 1 loop
    v_case := v_scenarios -> v_idx;
    v_comments := '[]'::jsonb;
    v_assignees := array(
      select jsonb_array_elements_text(v_case -> 'assignees')
    );

    -- Интервалы участия.
    for v_iv in select * from jsonb_array_elements(v_case -> 'intervals') loop
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', 'te-' || v_idx || '-' || (v_iv->>'uid') || '-' || (v_iv->>'from_h'),
        'type', 'time_event',
        'userId', v_iv->>'uid',
        'timestamp', floor(extract(epoch from
          v_base + ((v_iv->>'from_h')::numeric * interval '1 hour')) * 1000)::bigint,
        'text', jsonb_build_object(
          'type', coalesce(v_iv->>'type', 'production'),
          'startTime', to_char(
            (v_base + ((v_iv->>'from_h')::numeric * interval '1 hour')) at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'endTime', to_char(
            (v_base + ((v_iv->>'to_h')::numeric * interval '1 hour')) at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
          'subjectUserId', v_iv->>'uid',
          'taskId', v_task_id,
          'workplaceId', v_wp_id,
          'participantsSnapshot', to_jsonb(v_assignees)
        )::text
      ));
    end loop;

    -- Тираж сегментов.
    for v_seg in select * from jsonb_array_elements(v_case -> 'segments') loop
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', 'st-' || v_idx || '-' || (v_seg->>'end_h'),
        'type', 'quantity_stage_total',
        'userId', v_assignees[1],
        'timestamp', floor(extract(epoch from
          v_base + ((v_seg->>'end_h')::numeric * interval '1 hour')) * 1000)::bigint,
        'text', jsonb_build_object('actual', (v_seg->>'qty')::numeric)::text
      ));
    end loop;

    -- Задачу пересоздаём под каждый сценарий; всё это откатится.
    execute format(
      'delete from public.tasks where id::text = %L', v_task_id);
    execute format(
      'insert into public.tasks(id, order_id, stage_id, stage_group_key, status,
         assignees, comments, captured_by_workplace_id)
       values (%L, %L, %L, %L, %L, %L::text[], %L::jsonb, %L)',
      v_task_id, v_order_id, v_wp_id, v_wp_id, 'inProgress',
      '{' || array_to_string(v_assignees, ',') || '}',
      v_comments::text, v_wp_id);

    update public.workplaces
       set split_quantity_by_time = (v_case->>'split')::boolean
     where id::text = v_wp_id;

    -- Сверяем каждую ожидаемую долю.
    v_expect := v_case -> 'expect';
    v_report := v_report || E'\n' || (v_case->>'name') || E'\n';

    for v_uid in select jsonb_object_keys(v_expect) loop
      v_want := (v_expect ->> v_uid)::numeric;
      select round(sum(p.raw_share), 4)
        into v_actual
        from public.task_quantity_share_preview(v_task_id) p
       where p.employee_id = v_uid;

      v_checks := v_checks + 1;
      if v_actual is null or abs(v_actual - v_want) > 0.01 then
        v_failures := v_failures + 1;
        v_line := format('   ПРОВАЛ %-4s ожидалось %s, получено %s',
                         v_uid, v_want, coalesce(v_actual::text, 'нет строки'));
      else
        v_line := format('   ок     %-4s %s', v_uid, v_actual);
      end if;
      v_report := v_report || v_line || E'\n';
    end loop;

    -- Лишние участники (кому доля не должна была достаться) — тоже провал.
    for v_uid in
      select p.employee_id
        from public.task_quantity_share_preview(v_task_id) p
       group by p.employee_id
      except
      select jsonb_object_keys(v_expect)
    loop
      v_failures := v_failures + 1;
      v_checks := v_checks + 1;
      v_report := v_report
        || format('   ПРОВАЛ лишний участник %s', v_uid) || E'\n';
    end loop;
  end loop;

  -- L. Идемпотентность: повторный пересчёт на тех же данных обязан дать тот
  -- же результат, иначе доли «поплывут» при каждом перезаходе в задачу.
  -- Проверяем уже пишущей функцией — на последней собранной задаче.
  declare
    v_first jsonb;
    v_second jsonb;
  begin
    perform public.recompute_task_quantity_shares(v_task_id);
    select jsonb_agg(jsonb_build_object('u', c->>'userId', 't', c->>'text')
                     order by c->>'userId', c->>'text')
      into v_first
      from jsonb_array_elements(public.task_comments_to_array(
             (select t.comments::jsonb from public.tasks t
               where t.id::text = v_task_id))) c
     where c->>'type' = 'quantity_share';

    perform public.recompute_task_quantity_shares(v_task_id);
    select jsonb_agg(jsonb_build_object('u', c->>'userId', 't', c->>'text')
                     order by c->>'userId', c->>'text')
      into v_second
      from jsonb_array_elements(public.task_comments_to_array(
             (select t.comments::jsonb from public.tasks t
               where t.id::text = v_task_id))) c
     where c->>'type' = 'quantity_share';

    v_checks := v_checks + 1;
    v_report := v_report || chr(10) || 'L. идемпотентность пересчёта' || chr(10);
    if v_first is null then
      v_failures := v_failures + 1;
      v_report := v_report
        || '   ПРОВАЛ пересчёт не записал ни одной доли' || chr(10);
    elsif v_first is distinct from v_second then
      v_failures := v_failures + 1;
      v_report := v_report
        || '   ПРОВАЛ второй пересчёт дал другой результат' || chr(10);
    else
      v_report := v_report
        || format('   ок     записей %s, повтор совпал',
                  jsonb_array_length(v_first)) || chr(10);
    end if;
  end;

  raise exception E'% \n\nИТОГ: проверок %, провалов %.\n%',
    E'\n===== ПРОВЕРКА РАСПРЕДЕЛЕНИЯ КОЛИЧЕСТВА =====' || v_report,
    v_checks, v_failures,
    case when v_failures = 0
         then 'Всё сошлось. Данные откачены, база не изменена.'
         else 'ЕСТЬ РАСХОЖДЕНИЯ — смотрите строки ПРОВАЛ выше.' end;
end
$verify$;
