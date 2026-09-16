-- Повторная пересмена на том же отрезке этапа — не событие, а промах.
--
-- 16.09.2026, ЗК-2026.09.16-2 («Бабинорезка», совместный этап с помощником):
-- 10:28:29 — пересмена записана целиком (количество 10 м, интервал помощника
-- закрыт, помощник снят с этапа, открыт интервал shift_change владельца,
-- shift_pause_state + shift_pause). 10:28:44 — то же нажатие ещё раз:
-- количество 1 м и вторая пара shift_pause_state/shift_pause. Интервал при
-- этом не задвоился: open_interval сам пропускает открытие, когда у человека
-- уже открыт интервал того же типа. А вот комментарии легли вторым слоем — и
-- в выработку этапа попало лишнее количество.
--
-- Клиент чинится отдельно (замок кнопки на время диалогов и защита локальных
-- записей от опоздавшего перечита), но старые сборки на планшетах остаются в
-- цеху надолго. Поэтому правило переносится на сервер: пока у сотрудника
-- открыт интервал shift_change, повторные комментарии пересмены не
-- применяются.
--
-- Тип quantity_stage_total пишется ровно в одном месте клиента — в пересмене
-- (kStageTotalCommentType в tasks_screen.dart). Личное количество
-- (quantity_done) и завершение этапа идут другими путями и этим правилом не
-- затрагиваются.

create or replace function public.task_shift_pause_users(p_comments jsonb)
returns text[]
language sql
immutable
as $$
  select coalesce(
    array_agg(distinct coalesce(
      public.task_json_payload(c->>'text')->>'subjectUserId',
      c->>'userId'
    )),
    array[]::text[]
  )
  from jsonb_array_elements(public.task_comments_to_array(p_comments)) c
  where c->>'type' = 'time_event'
    and public.task_json_payload(c->>'text') is not null
    and (public.task_json_payload(c->>'text')->>'endTime') is null
    and coalesce(public.task_json_payload(c->>'text')->>'type', '') = 'shift_change';
$$;

comment on function public.task_shift_pause_users(jsonb) is
  'Сотрудники с открытым интервалом пересмены (shift_change) на момент вызова.';

create or replace function public.task_apply_ops(
  p_task_id text,
  p_stage_id text,
  p_comments jsonb,
  p_assignees text[],
  p_ops jsonb,
  p_at timestamptz default null
) returns jsonb
language plpgsql
stable
as $function$
declare
  v_comments jsonb := public.task_comments_to_array(p_comments);
  v_assignees text[] := coalesce(p_assignees, array[]::text[]);
  v_now timestamptz := coalesce(p_at, clock_timestamp());
  v_now_ms bigint; v_offset int := 0; v_op jsonb; v_kind text; v_user text;
  v_subject text; v_note text; v_type text; v_open int; v_payload jsonb;
  v_event jsonb; v_ts bigint;
  -- Считается ОДИН раз, до применения операций: интервал пересмены открывает
  -- сама эта пачка, и проверяй мы состояние по ходу — отбрасывались бы
  -- собственные, первые shift_pause_state и shift_pause.
  v_shift_paused_users text[] := public.task_shift_pause_users(v_comments);
begin
  v_now_ms := floor(extract(epoch from v_now) * 1000);
  if p_ops is null or jsonb_typeof(p_ops) <> 'array' then
    raise exception 'ops must be a json array';
  end if;
  for v_op in select value from jsonb_array_elements(p_ops)
  loop
    v_kind := coalesce(v_op->>'op', '');
    if v_kind = 'add_assignee' then
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' and array_position(v_assignees, v_user) is null then
        v_assignees := array_append(v_assignees, v_user);
      end if;
    elsif v_kind = 'remove_assignee' then
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' then v_assignees := array_remove(v_assignees, v_user); end if;
    elsif v_kind = 'claim_stage' then
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' then v_assignees := array[v_user]; end if;
    elsif v_kind = 'comment' then
      if public.task_finish_record_is_repeat(v_comments, v_op->>'userId', coalesce(v_op->>'type', ''), v_op->>'text') then continue; end if;
      -- Этап уже стоит на пересмене этого сотрудника: повтор.
      if coalesce(v_op->>'type', '') in ('quantity_stage_total', 'shift_pause_state', 'shift_pause')
         and array_position(v_shift_paused_users, trim(coalesce(v_op->>'userId', ''))) is not null then
        continue;
      end if;
      v_ts := v_now_ms + v_offset; v_offset := v_offset + 1;
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', coalesce(nullif(trim(coalesce(v_op->>'id', '')), ''), v_ts::text),
        'type', coalesce(v_op->>'type', ''), 'text', coalesce(v_op->>'text', ''),
        'userId', coalesce(v_op->>'userId', ''), 'timestamp', v_ts));
    elsif v_kind = 'close_interval' then
      v_subject := trim(coalesce(v_op->>'subject', '')); v_note := v_op->>'note';
      v_open := public.task_open_interval_index(v_comments, v_subject);
      if v_open is not null then
        v_payload := public.task_json_payload(v_comments->v_open->>'text')
          || jsonb_build_object('endTime', public.task_iso_utc(v_now));
        if v_note is not null then v_payload := v_payload || jsonb_build_object('note', v_note); end if;
        v_comments := jsonb_set(v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      end if;
    elsif v_kind = 'open_interval' then
      v_subject := trim(coalesce(v_op->>'subject', ''));
      v_type := coalesce(v_op->>'type', ''); v_note := v_op->>'note';
      if v_subject = '' or v_type = '' then continue; end if;
      v_open := public.task_open_interval_index(v_comments, v_subject);
      if v_open is not null then
        v_payload := public.task_json_payload(v_comments->v_open->>'text');
        if coalesce(v_payload->>'type', '') = v_type then continue; end if;
        v_payload := v_payload || jsonb_build_object('endTime', public.task_iso_utc(v_now));
        if v_note is not null then v_payload := v_payload || jsonb_build_object('note', v_note); end if;
        v_comments := jsonb_set(v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      end if;
      v_ts := v_now_ms + v_offset; v_offset := v_offset + 1;
      v_event := jsonb_strip_nulls(jsonb_build_object(
        'type', v_type, 'startTime', public.task_iso_utc(v_now),
        'initiatedBy', coalesce(v_op->>'initiatedBy', v_subject),
        'subjectUserId', v_subject, 'taskId', p_task_id,
        'workplaceId', coalesce(v_op->>'workplaceId', p_stage_id),
        'participantsSnapshot', coalesce(v_op->'participants', '[]'::jsonb),
        'executionMode', v_op->>'executionMode', 'helperId', v_op->>'helperId', 'note', v_note));
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', v_ts::text || '-' || v_subject, 'type', 'time_event',
        'text', v_event::text, 'userId', v_subject, 'timestamp', v_ts));
    else
      raise exception 'Неизвестная операция этапа: %', v_kind;
    end if;
  end loop;
  select coalesce(jsonb_agg(value order by public.task_comment_millis(value->>'timestamp'), ord), '[]'::jsonb)
    into v_comments from jsonb_array_elements(v_comments) with ordinality as t(value, ord);
  return jsonb_build_object('assignees', to_jsonb(v_assignees), 'comments', v_comments);
end
$function$;
