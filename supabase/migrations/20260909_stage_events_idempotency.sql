-- ============================================================================
-- Повторяемость действий этапа: ключ запроса (2026-09-09)
--
-- Зачем
-- -----
-- Действия цеха уходят одним вызовом `task_apply_stage_events` — это уже
-- защищает от «половина записалась». Но если ответ не дошёл (25-секундные
-- таймауты на цеховой сети — обычное дело), клиент не знает, применилось оно
-- или нет. Сейчас он просто показывает ошибку, и человек нажимает кнопку
-- второй раз. Иногда действие при этом применяется дважды: комментарий
-- задваивается, открывается второй интервал.
--
-- Поэтому автоматических повторов до сих пор и не было — повторять было
-- опасно. Ключ запроса снимает это ограничение: повтор с тем же ключом
-- возвращает результат первой попытки и ничего не меняет.
--
-- Как работает
-- ------------
-- Клиент генерирует uuid на КАЖДОЕ НАМЕРЕНИЕ (а не на попытку) и повторяет
-- вызов с тем же ключом, пока не получит ответ. Первый дошедший вызов
-- записывает ключ и результат; все следующие отдают сохранённый результат.
--
-- Вставка ключа идёт ПЕРЕД применением операций и в той же транзакции: если
-- две попытки долетели одновременно, вторая упрётся в первичный ключ,
-- дождётся конца первой и вернёт её результат.
--
-- Старые вызовы без ключа продолжают работать как раньше — ничего не
-- записывают и ничего не проверяют.
-- ============================================================================

begin;

create table if not exists public.task_event_requests (
  request_id uuid        primary key,
  task_id    text        not null,
  result     jsonb,
  created_at timestamptz not null default now()
);

comment on table public.task_event_requests is
  'Ключи применённых действий этапа. Повтор вызова с тем же ключом возвращает сохранённый результат вместо повторного применения операций.';

-- Журнал нужен на время жизни повторов, а не вечно: неделю с запасом.
create index if not exists task_event_requests_created_at_idx
  on public.task_event_requests (created_at);

alter table public.task_event_requests enable row level security;

drop policy if exists task_event_requests_read on public.task_event_requests;
create policy task_event_requests_read on public.task_event_requests
  for select to authenticated, anon using (true);

-- Число аргументов меняется, поэтому старую версию убираем: иначе получилась
-- бы перегрузка, и вызов без ключа стал бы неоднозначным.
drop function if exists public.task_apply_stage_events(text, jsonb, text);

create or replace function public.task_apply_stage_events(
  p_task_id         text,
  p_ops             jsonb,
  p_expect_assignee text default null,
  p_request_id      uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_task      tasks%rowtype;
  v_result    jsonb;
  v_assignees text[];
  v_known     jsonb;
begin
  if coalesce(trim(p_task_id), '') = '' then
    raise exception 'task_id is required';
  end if;

  -- Повтор уже применённого действия: отдаём прежний результат.
  if p_request_id is not null then
    select r.result into v_known
      from public.task_event_requests r
     where r.request_id = p_request_id;
    if found then
      return coalesce(v_known, '{}'::jsonb);
    end if;
  end if;

  select * into v_task from tasks where id::text = p_task_id for update;
  if not found then
    raise exception 'Задача % не найдена.', p_task_id;
  end if;

  v_assignees := coalesce(v_task.assignees, array[]::text[]);
  if coalesce(trim(p_expect_assignee), '') <> ''
     and array_position(v_assignees, trim(p_expect_assignee)) is null then
    raise exception 'Сотрудник % больше не назначен на этап.', p_expect_assignee;
  end if;

  -- Ключ занимаем ДО применения операций: параллельная вторая попытка
  -- заблокируется здесь и после коммита первой увидит её результат.
  if p_request_id is not null then
    insert into public.task_event_requests (request_id, task_id)
    values (p_request_id, p_task_id)
    on conflict (request_id) do nothing;

    if not found then
      select r.result into v_known
        from public.task_event_requests r
       where r.request_id = p_request_id;
      return coalesce(v_known, '{}'::jsonb);
    end if;
  end if;

  v_result := public.task_apply_ops(
    p_task_id, v_task.stage_id, v_task.comments, v_assignees, p_ops);

  update tasks
     set comments  = v_result->'comments',
         assignees = array(select jsonb_array_elements_text(v_result->'assignees'))
   where id::text = p_task_id;

  if p_request_id is not null then
    update public.task_event_requests
       set result = v_result
     where request_id = p_request_id;
  end if;

  return v_result;
end
$function$;

grant execute on function public.task_apply_stage_events(text, jsonb, text, uuid)
  to authenticated, anon;

-- Уборка старых ключей. Повторы живут минуты, недели с запасом хватает.
--
-- Тот же срок зашит в клиенте (`kStageRequestMaxAge` в stage_event_outbox.dart):
-- очередь перестаёт слать намерение ровно тогда, когда сервер уже мог забыть
-- его ключ. Менять эти два срока можно только вместе — иначе просроченный
-- повтор задвоит запись.
create or replace function public.prune_task_event_requests(p_keep interval default '7 days')
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_deleted integer;
begin
  delete from public.task_event_requests
   where created_at < now() - p_keep;
  get diagnostics v_deleted = row_count;
  return v_deleted;
end
$function$;

commit;

-- ============================================================================
-- Ежедневная уборка (применено отдельно, вне транзакции выше).
--
-- Ночью, когда цех не работает. `cron.schedule` с тем же именем перезаписывает
-- задание, поэтому повторный запуск безопасен.
-- ============================================================================
-- select cron.schedule(
--   'prune-task-event-requests',
--   '17 3 * * *',
--   $$select public.prune_task_event_requests();$$
-- );
