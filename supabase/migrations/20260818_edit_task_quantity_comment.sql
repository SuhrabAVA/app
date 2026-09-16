-- Правка зафиксированного количества техлидом.
--
-- Сотрудник иногда вводит неверное число. Техлид исправляет его из аналитики,
-- и правка должна попасть сразу в три места: в аналитику сотрудника, в
-- комментарии заказа и — если этап формирует фактическое количество — в
-- orders.actual_qty. Первые два это одна и та же запись в tasks.comments
-- (аналитика считается из неё), третье пересчитывает клиент вызовом
-- recomputeOrderActualQty после успешной правки.
--
-- Почему функция, а не update с клиента: комментарии лежат ОДНИМ jsonb в
-- строке задачи, и клиентский цикл «прочитать всё → заменить элемент →
-- записать всё» затирает комментарии, которые сотрудник успел записать между
-- чтением и записью. На идущем этапе туда каждую минуту падают time_event,
-- так что окно в сотни миллисекунд — не теория. Здесь строка блокируется
-- (for update), читается и пишется в одной транзакции.

begin;

do $preflight$
begin
  if to_regclass('public.tasks') is null then
    raise exception using
      message = 'public.tasks is missing',
      hint = 'Restore the tasks table before applying this migration.';
  end if;

  -- Именно to_regprocedure: to_regproc не разбирает список аргументов и на
  -- сигнатуре со скобками молча возвращает NULL — проверка «функции нет»
  -- срабатывала на существующей функции.
  if to_regprocedure('public.task_comments_to_array(jsonb)') is null then
    raise exception using
      message = 'public.task_comments_to_array(jsonb) is missing',
      hint = 'Apply the migration that introduces task_comments_to_array first.';
  end if;
end
$preflight$;

-- p_task_id text и сопоставление через id::text — та же схема, что в
-- complete_task_stage: не завязываемся на то, uuid в колонке или text.
create or replace function public.update_task_quantity_comment(
  p_task_id text,
  p_comment_id text,
  p_new_text text,
  p_audit_text text,
  p_audit_user_id text
)
returns jsonb
language plpgsql
as $function$
declare
  v_now_ms bigint := floor(extract(epoch from clock_timestamp()) * 1000);
  v_task tasks%rowtype;
  v_comments jsonb;
  v_target jsonb;
  v_old_text text;
begin
  if coalesce(trim(p_task_id), '') = '' or coalesce(trim(p_comment_id), '') = '' then
    raise exception using
      message = 'task id and comment id are required',
      errcode = '22023';
  end if;
  if coalesce(trim(p_new_text), '') = '' then
    raise exception using
      message = 'new quantity payload is empty',
      errcode = '22023';
  end if;

  -- Блокируем строку: параллельная правка того же задания подождёт, а не
  -- перезапишет наш массив своим устаревшим снимком.
  select * into v_task
    from public.tasks
   where id::text = p_task_id
   for update;

  if not found then
    raise exception using
      message = 'task not found',
      errcode = 'P0002';
  end if;

  v_comments := public.task_comments_to_array(v_task.comments::jsonb);

  select elem
    into v_target
    from jsonb_array_elements(v_comments) as elem
   where elem->>'id' = p_comment_id
   limit 1;

  if v_target is null then
    raise exception using
      message = 'quantity record not found in task comments',
      errcode = 'P0002',
      hint = 'The record was probably rewritten by another correction. Reload analytics and retry.';
  end if;

  -- Править разрешено только записи количества: подменять произвольный
  -- комментарий (старт, паузу, проблему) эта функция не должна.
  if coalesce(v_target->>'type', '') not in
       ('quantity_done', 'quantity_team_total', 'quantity_share') then
    raise exception using
      message = 'only quantity records can be corrected',
      errcode = '22023',
      detail = coalesce(v_target->>'type', 'unknown');
  end if;

  v_old_text := v_target->>'text';

  select coalesce(
           jsonb_agg(
             case
               when elem->>'id' = p_comment_id
                 then jsonb_set(elem, '{text}', to_jsonb(p_new_text))
               else elem
             end
             order by ord
           ),
           '[]'::jsonb
         )
    into v_comments
    from jsonb_array_elements(v_comments) with ordinality as t(elem, ord);

  -- След правки виден в истории заказа наравне с обычными комментариями.
  if coalesce(trim(p_audit_text), '') <> '' then
    v_comments := v_comments || jsonb_build_array(jsonb_build_object(
      'id', gen_random_uuid()::text,
      'type', 'quantity_edit',
      'text', p_audit_text,
      'userId', coalesce(p_audit_user_id, ''),
      'timestamp', v_now_ms
    ));
  end if;

  update public.tasks
     set comments = v_comments
   where id::text = p_task_id;

  return jsonb_build_object(
    'task_id', p_task_id,
    'comment_id', p_comment_id,
    'order_id', v_task.order_id::text,
    'stage_id', v_task.stage_id::text,
    'old_text', v_old_text,
    'new_text', p_new_text
  );
end
$function$;

-- SECURITY INVOKER (по умолчанию): правка идёт под RLS вызывающего, как и
-- остальная работа с tasks. Проверку «это техлид» делает приложение.
grant execute on function public.update_task_quantity_comment(text, text, text, text, text)
  to anon, authenticated, service_role;

commit;
