-- ============================================================================
-- Целостность данных, шаг 5: повторное «Завершить» не задваивает количество
-- (2026-09-14)
--
-- Что чинит
-- ---------
-- В отдельном режиме (Упаковка, Скотч, Сборка…) «Завершить» пишет личное
-- количество (quantity_done) и отметку user_done. На 14.09 в базе 23 повтора:
-- тот же сотрудник, то же число, разрыв 20–75 секунд. Только на Упаковке
-- это 43 108 лишних единиц в факте этапа и в сдельной.
--
-- Причина: клиент отправлял количество, отметку и закрытие интервала тремя
-- отдельными вызовами task_apply_stage_events, у каждого свой ключ повтора.
-- Ключ защищает от повтора ОДНОГО и того же запроса, но не от второго нажатия:
-- на цеховой сети первый вызов уходит в очередь повторов, экран остаётся в
-- прежнем состоянии, сотрудник жмёт «Завершить» ещё раз — это уже новое
-- действие с новым ключом.
--
-- Что делает миграция
-- -------------------
-- task_apply_ops пропускает quantity_done / user_done, если сотрудник уже
-- завершил участие после последнего входа в работу (интервала времени или
-- отметки старта). Повтор тогда ничего не пишет, а клиент получает актуальное
-- состояние и показывает «завершил». Новое участие (новый старт) снова
-- разрешает завершение.
--
-- Для quantity_done повтором считается и та же запись с тем же числом без
-- отметки user_done — так выглядит повтор от старых версий приложения,
-- у которых отметка терялась отдельным запросом.
-- ============================================================================

begin;

create or replace function public.task_finish_record_is_repeat(
  p_comments jsonb,
  p_user text,
  p_type text,
  p_text text
)
returns boolean
language plpgsql
immutable
as $function$
declare
  v_user text := trim(coalesce(p_user, ''));
  v_comments jsonb := public.task_comments_to_array(p_comments);
  v_start_ms bigint;
begin
  if v_user = '' or coalesce(p_type, '') not in ('quantity_done', 'user_done') then
    return false;
  end if;

  -- Последний вход сотрудника в работу.
  select max(public.task_comment_millis(c->>'timestamp'))
    into v_start_ms
    from jsonb_array_elements(v_comments) c
   where (
           c->>'type' = 'time_event'
           and coalesce(public.task_json_payload(c->>'text')->>'subjectUserId',
                        c->>'userId') = v_user
         )
      or (
           c->>'type' in ('start', 'resume', 'joined', 'shift_resume', 'setup_start')
           and c->>'userId' = v_user
         );

  return exists (
    select 1
      from jsonb_array_elements(v_comments) c
     where c->>'userId' = v_user
       and public.task_comment_millis(c->>'timestamp') > coalesce(v_start_ms, 0)
       and (
         c->>'type' = 'user_done'
         or (
           p_type = 'quantity_done'
           and c->>'type' = 'quantity_done'
           and trim(coalesce(c->>'text', '')) = trim(coalesce(p_text, ''))
         )
       )
  );
end
$function$;

comment on function public.task_finish_record_is_repeat(jsonb, text, text, text) is
  'Истина, если сотрудник уже завершил участие в этапе после последнего входа '
  'в работу: повторная запись количества или отметки «завершил» задвоила бы '
  'выработку.';

do $patch$
declare
  v_sig constant regprocedure :=
    'public.task_apply_ops(text,text,jsonb,text[],jsonb,timestamptz)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_anchor constant text := 'elsif v_kind = ''comment'' then';
  v_guard constant text :=
    ' if public.task_finish_record_is_repeat(v_comments, v_op->>''userId'', '
    || 'coalesce(v_op->>''type'', ''''), v_op->>''text'') then continue; end if;';
  v_count int;
begin
  if position('task_finish_record_is_repeat' in v_def) > 0 then
    raise notice 'task_apply_ops уже пропатчена — пропуск';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, '')))
             / length(v_anchor);
  if v_count <> 1 then
    raise exception 'Шаблон comment найден % раз(а) вместо 1 — '
      'функция изменилась, миграцию нужно пересобрать', v_count;
  end if;

  v_def := replace(v_def, v_anchor, v_anchor || v_guard);
  execute v_def;
end
$patch$;

commit;
