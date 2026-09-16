-- ============================================================================
-- Расчёт долей количества по фактически отработанному времени (2026-08-21)
--
-- Считаем НА СЕРВЕРЕ: Windows- и Android-клиенты не должны разойтись в
-- арифметике зарплаты. Интервалы участия — источник истины, доли — производная
-- величина, пересчитываемая идемпотентно.
--
-- Откуда берутся интервалы
-- ------------------------
-- Отдельной таблицы нет и не нужно: журнал участия уже ведётся в
-- tasks.comments записями type = 'time_event'. В поле text лежит JSON
-- {type, startTime, endTime, subjectUserId, ...}, по одной записи на каждого
-- участника, с типом production/pause/problem/shift_change/setup. Пауза не
-- «вычитается» — это отдельный тип интервала, в production он не попадает,
-- поэтому в t_i её нет автоматически.
--
-- Приладка (setup) в t_i НЕ входит: она оплачивается отдельной строкой по
-- цене рабочего места и достаётся тому, кто наладку начал. Засчитав её ещё и
-- во время работы, мы заплатили бы наладчику дважды за один и тот же час.
--
-- Формула в пределах одного сегмента
-- ----------------------------------
--   t_i     — сумма production-интервалов сотрудника внутри сегмента;
--   T_total — сумма t_i по всем участникам (ФАКТИЧЕСКАЯ: ушедший через 2 часа
--             из пяти добавляет 2, а не 5);
--   q_i     = Q_сегмента × t_i / T_total.
-- T_total = 0 (мгновенное завершение, сбой часов) — делим поровну, а не
-- падаем: остановить завершение этапа из-за битой метки времени дороже.
--
-- Округление — ОДИН ceil на этап, а не на сегмент: неполный пакет считается
-- за целый, но округлять каждый кусок значило бы округлять по три раза за
-- смену. Следствие принято сознательно: сумма долей может превысить тираж на
-- величину до (число участников − 1).
--
-- Записи пишутся ПО СЕГМЕНТАМ, с меткой конца сегмента. Иначе этап, начатый
-- 31-го и закрытый 1-го, целиком упал бы в новый месяц и сломал обе ведомости.
-- Добавку от округления кладём в последнюю запись сотрудника — сумма его
-- записей остаётся равной итоговой доле.
--
-- Рабочие места с split_quantity_by_time = false (Флексопечать, Бабинорезка,
-- автоматы, Труба, Фри, Окно, Листорезка): бригада обслуживает одну машину,
-- тираж делает станок. Там каждому пишется полное Q, и ceil не нужен.
--
-- Проверять расчёт можно, ничего не записывая:
--   select * from public.task_quantity_share_preview('<task_id>');
-- ============================================================================

begin;

do $preflight$
begin
  if to_regclass('public.tasks') is null then
    raise exception using message = 'public.tasks is missing';
  end if;

  if to_regprocedure('public.task_comments_to_array(jsonb)') is null then
    raise exception using
      message = 'public.task_comments_to_array(jsonb) is missing',
      hint = 'Apply the migration that introduces task_comments_to_array first.';
  end if;

  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'workplaces'
       and column_name = 'split_quantity_by_time'
  ) then
    raise exception using
      message = 'public.workplaces.split_quantity_by_time is missing',
      hint = 'Apply 20260821_quantity_share_by_time.sql first.';
  end if;
end
$preflight$;

-- ── Метка времени комментария в миллисекундах ───────────────────────────────
--
-- Единицы в tasks.comments смешанные: старые записи в секундах, новые в
-- миллисекундах, а совсем древние — в микросекундах. Пороги те же, что в
-- lib/modules/tasks/task_model.dart (normalizeEpochToMillis): разъехавшись,
-- клиент и сервер показали бы разное время одного события.
create or replace function public.task_comment_millis(p_value text)
returns bigint
language plpgsql
immutable
as $function$
declare
  v text := trim(coalesce(p_value, ''));
  v_ms bigint;
begin
  if v = '' then return 0; end if;
  -- Метка может прийти и строкой ISO-8601 (легаси-записи).
  if v ~ '^-?\d+$' then
    v_ms := v::bigint;
  else
    begin
      v_ms := floor(extract(epoch from v::timestamptz) * 1000)::bigint;
    exception when others then
      return 0;
    end;
  end if;

  if v_ms <= 0 then return v_ms; end if;
  if v_ms > 10000000000000 then return v_ms / 1000; end if;   -- микросекунды
  if v_ms < 2000000000 then return v_ms * 1000; end if;       -- секунды
  return v_ms;
end
$function$;

comment on function public.task_comment_millis(text) is
  'Метка комментария задачи в миллисекундах, независимо от единиц исходной '
  'записи. Пороги синхронизированы с normalizeEpochToMillis в task_model.dart.';

-- ── Безопасный разбор payload записи ────────────────────────────────────────
--
-- В text лежит либо JSON (time_event, количество), либо свободный текст
-- (легаси). Прямой ::jsonb на свободном тексте валит всю транзакцию, поэтому
-- разбор всегда через эту функцию.
create or replace function public.task_quantity_payload(p_text text)
returns jsonb
language plpgsql
immutable
as $function$
declare
  v text := trim(coalesce(p_text, ''));
begin
  if v = '' or left(v, 1) <> '{' then return null; end if;
  begin
    return v::jsonb;
  exception when others then
    return null;
  end;
end
$function$;

comment on function public.task_quantity_payload(text) is
  'JSON-payload записи задачи или NULL, если это свободный текст.';

-- ── Число из записи количества ──────────────────────────────────────────────
--
-- Раньше JSON разбирался «первым числом в строке» и работал лишь потому, что
-- ключ actual стоит в payload первым. Перестановка ключей молча вернула бы
-- план вместо факта, поэтому actual читается явно.
create or replace function public.task_quantity_value(p_value text)
returns double precision
language plpgsql
immutable
as $function$
declare
  v_payload jsonb := public.task_quantity_payload(p_value);
  v text := replace(coalesce(p_value, ''), ',', '.');
  m text[];
begin
  if v_payload is not null and v_payload ? 'actual' then
    begin
      return (v_payload->>'actual')::double precision;
    exception when others then
      null;  -- битый actual — разбираем дальше как свободный текст
    end;
  end if;

  m := regexp_match(v, '=\s*(-?\d+(?:\.\d+)?)');
  if m is not null then return m[1]::double precision; end if;

  m := regexp_match(v, '(-?\d+(?:\.\d+)?)\s*пач', 'i');
  if m is not null then
    declare
      packs double precision := m[1]::double precision;
      in_pack_match text[] := regexp_match(v, '[x×*]\s*(-?\d+(?:\.\d+)?)');
    begin
      if in_pack_match is not null then
        return packs * in_pack_match[1]::double precision;
      end if;
    end;
  end if;

  begin
    return nullif(trim(v), '')::double precision;
  exception when others then
    m := regexp_match(v, '-?\d+(?:\.\d+)?');
    if m is not null then return m[1]::double precision; end if;
  end;
  return 0;
end
$function$;

-- ── Предпросмотр расчёта (только чтение) ────────────────────────────────────
--
-- Отдельная функция, потому что расчёт зарплаты нужно уметь проверить, ничего
-- не записав: одна строка на пару «сотрудник × сегмент», с секундами и сырой
-- (неокруглённой) долей. Итоговое округление применяет уже writer.
create or replace function public.task_quantity_share_preview(p_task_id text)
returns table (
  employee_id text,
  role text,
  segment_end timestamptz,
  seconds numeric,
  raw_share numeric
)
language plpgsql
stable
as $function$
declare
  v_task tasks%rowtype;
  v_comments jsonb;
  v_assignees text[];
  v_owner text;
  v_helpers text[];
  v_split boolean;
  v_workplace text;
  v_now timestamptz := now();
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
    select m.seg_end, m.qty
      from (
        select to_timestamp(
                 public.task_comment_millis(c->>'timestamp') / 1000.0) as seg_end,
               public.task_quantity_value(c->>'text') as qty
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
                coalesce(nullif(p.ev->>'endTime', '')::timestamptz, v_now),
                v_seg.seg_end
              )
              - greatest((p.ev->>'startTime')::timestamptz, v_prev)
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
      select w.uid, w.secs from worked w where w.secs > 0
    ),
    participants as (
      select p.uid, p.secs from positive p
      union all
      -- T_total = 0: в сегменте никто не отработал ни секунды. Делим поровну
      -- между исполнителями задачи.
      select a.uid, 0::numeric
        from unnest(v_assignees) as a(uid)
       where not exists (select 1 from positive)
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

comment on function public.task_quantity_share_preview(text) is
  'Предпросмотр распределения количества по участникам: строка на пару '
  '«сотрудник × сегмент», секунды и сырая доля до округления. Ничего не пишет.';

-- ── Пересчёт долей (запись) ─────────────────────────────────────────────────
create or replace function public.recompute_task_quantity_shares(p_task_id text)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_task tasks%rowtype;
  v_comments jsonb;
  v_kept jsonb := '[]'::jsonb;
  v_split boolean;
  v_workplace text;
  v_unit text := '';
  v_report jsonb := '[]'::jsonb;
  v_row record;
  v_offset int := 0;
  v_display text;
begin
  if coalesce(trim(p_task_id), '') = '' then
    raise exception using message = 'task_id is required', errcode = '22023';
  end if;

  -- Комментарии лежат ОДНИМ jsonb в строке задачи, и на идущем этапе туда
  -- каждую минуту падают time_event. Без блокировки цикл «прочитать всё →
  -- заменить → записать всё» затирал бы записи, сделанные между чтением и
  -- записью (та же причина, что в update_task_quantity_comment).
  select * into v_task from public.tasks where id::text = p_task_id for update;
  if not found then
    raise exception 'Задача % не найдена.', p_task_id;
  end if;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);

  v_workplace := coalesce(
    nullif(trim(coalesce(v_task.captured_by_workplace_id::text, '')), ''),
    v_task.stage_id::text
  );
  select w.split_quantity_by_time, coalesce(w.unit, '')
    into v_split, v_unit
    from public.workplaces w
   where w.id::text = v_workplace;
  v_split := coalesce(v_split, true);
  v_unit := coalesce(v_unit, '');

  -- Идемпотентность: выбрасываем ТОЛЬКО свои прежние записи. Доли, введённые
  -- руками, и правки техлида (update_task_quantity_comment) не помечены
  -- generated и переживают пересчёт.
  select coalesce(jsonb_agg(t.c order by t.ord), '[]'::jsonb)
    into v_kept
    from jsonb_array_elements(v_comments) with ordinality as t(c, ord)
   where not (
     t.c->>'type' = 'quantity_share'
     and coalesce(
           public.task_quantity_payload(t.c->>'text')->>'generated', '') = 'true'
   );

  -- Отчёт — по участнику целиком (не по сегментам): его читает человек.
  select coalesce(jsonb_agg(jsonb_build_object(
           'employee_id', r.employee_id,
           'role', r.role,
           'seconds', r.seconds,
           'raw_share', r.raw_share,
           'final_share', r.final_share
         ) order by r.employee_id), '[]'::jsonb)
    into v_report
    from (
      select b.employee_id,
             min(b.role) as role,
             sum(b.seconds) as seconds,
             sum(b.raw_share) as raw_share,
             case when v_split then ceil(sum(b.raw_share))
                  else sum(b.raw_share) end as final_share
        from public.task_quantity_share_preview(p_task_id) b
       group by b.employee_id
    ) r;

  for v_row in
    with base as (
      select * from public.task_quantity_share_preview(p_task_id)
    ),
    totals as (
      select b.employee_id,
             sum(b.raw_share) as raw_total,
             max(b.segment_end) as last_segment
        from base b
       group by b.employee_id
    ),
    finals as (
      select t.employee_id,
             t.raw_total,
             t.last_segment,
             case when v_split then ceil(t.raw_total) else t.raw_total end
               as final_total
        from totals t
    )
    select b.employee_id,
           b.role,
           b.segment_end,
           b.seconds,
           b.raw_share,
           -- Добавка от единственного округления оседает в последней записи
           -- сотрудника: сумма его записей равна итоговой доле.
           b.raw_share + case
             when b.segment_end = f.last_segment then f.final_total - f.raw_total
             else 0
           end as share
      from base b
      join finals f on f.employee_id = b.employee_id
     order by b.segment_end, b.employee_id
  loop
    if v_row.share <= 0 then
      continue;
    end if;

    -- Целое показываем без хвоста «.00»: подпись уходит в ленту задачи и в
    -- таблицы аналитики, где «5000» читается, а «5000.00» — нет.
    v_display := case
                   when v_row.share = trunc(v_row.share)
                     then trunc(v_row.share)::bigint::text
                   else trim(to_char(v_row.share, 'FM999999999990.99'))
                 end
                 || case when v_unit <> '' then ' ' || v_unit else '' end;

    v_kept := v_kept || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_share',
      'userId', v_row.employee_id,
      'timestamp',
        floor(extract(epoch from v_row.segment_end) * 1000)::bigint + v_offset,
      'text', jsonb_build_object(
        'actual', v_row.share,
        'unit', v_unit,
        'display', v_display,
        'generated', true,
        'role', v_row.role,
        'seconds', v_row.seconds,
        'raw_share', v_row.raw_share
      )::text
    ));
    v_offset := v_offset + 1;
  end loop;

  -- Клиент читает комментарии в порядке timestamp — сортируем, как это
  -- делают остальные пишущие функции.
  select coalesce(
           jsonb_agg(c order by public.task_comment_millis(c->>'timestamp')),
           '[]'::jsonb)
    into v_comments
    from jsonb_array_elements(v_kept) c;

  update public.tasks
     set comments = v_comments
   where id::text = p_task_id;

  return jsonb_build_object(
    'task_id', p_task_id,
    'workplace_id', v_workplace,
    'split_by_time', v_split,
    'participants', v_report
  );
end
$function$;

comment on function public.recompute_task_quantity_shares(text) is
  'Пересчитывает персональные доли количества по отработанному времени и '
  'перезаписывает сгенерированные quantity_share. Идемпотентна: повторный '
  'вызов на тех же данных даёт тот же результат.';

-- SECURITY DEFINER пишет в tasks мимо RLS вызывающего, поэтому право на
-- выполнение снимаем с public и выдаём точечно.
revoke execute on function public.recompute_task_quantity_shares(text) from public;
grant execute on function public.recompute_task_quantity_shares(text) to authenticated;

revoke execute on function public.task_quantity_share_preview(text) from public;
grant execute on function public.task_quantity_share_preview(text) to authenticated;

commit;
