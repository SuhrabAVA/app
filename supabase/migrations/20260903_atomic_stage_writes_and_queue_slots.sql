-- Атомарная запись событий этапа и один слот очереди на «рабочее место + этап».
--
-- ЗАЧЕМ
-- Три разных жалобы цеха оказались двумя дефектами записи.
--
-- 1. «Жанна не может начать заказ, хотя начинала». Задача
--    4190796b (РМ «С 2х листов»): в tasks.comments у неё есть exec_mode, start
--    и открытый интервал production с 02.09 11:15:04, а в tasks.assignees её
--    нет. Клиент писал assignees слепой перезаписью ВСЕГО массива, собранного
--    из снимка задачи в build (updateAssignees), и глотал ошибку в
--    catch { debugPrint }. На цеховой сети с 25-секундными таймаутами (см.
--    app_error_logs) это давало и потерянное обновление — чей PATCH долетел
--    последним, тот и переписал массив, — и «локально назначен, в базе нет».
--    Без строки в assignees экран не рисует сотруднику ряд кнопок вообще:
--    shouldShowCurrentUserRow требует либо назначения, либо разрешённого
--    старта, а старт запрещён незакрытым интервалом. Замок самозапирающийся.
--    Тот же механизм на задаче 9d0e8fbd потерял сразу двоих из шести.
--
-- 2. «Нет записей по пересмене». Задача e31e025e (РМ «Автомат маленький»,
--    02.09 03:10:03): интервал shift_change записан, а comments shift_pause,
--    shift_pause_state и строка в analytics — нет. Пересмена писалась четырьмя
--    независимыми запросами, каждый со своим catch { debugPrint }. Долетел
--    первый, остальные молча потерялись: ни оператор, ни база об этом не
--    узнали. Из 110 интервалов shift_change такой ровно один — но повторится
--    он обязательно, пока действие не транзакционно.
--
--    ВАЖНО про assignees на пересмене: пришедшая смена ЗАМЕНЯЕТ состав
--    исполнителей, и это не дефект. В совместном режиме этапом управляет
--    только assignees.first, поэтому дописать её в конец нельзя — она
--    осталась бы без кнопок. Отработанное время предыдущей смены живёт в
--    интервалах time_event (там свой subjectUserId) и от состава исполнителей
--    не зависит: аналитика читает интервалы.
--
-- 3. «Нельзя поднять ТОО Raw на листорезе». В workplace_queue_positions на
--    Листорезке у заказа 6f387f18 ДВЕ строки: поз. 28 со ссылкой на удалённую
--    задачу и поз. 47 на живую. Показ (priorityOfEntry) попадает в строку по
--    точному ключу задачи — в 47; перестановка (preferredPosition) выбирает
--    строку с меньшим номером — 28. Drag присваивает номер мёртвой строке,
--    живая уезжает в хвост, список читает живую — заказ не поднимается никогда.
--    Строки-сироты появляются потому, что OrderQueueSyncService при
--    перестроении маршрута удаляет и пересоздаёт задачи, а очередь не трогает.
--
-- ЧТО ДЕЛАЕМ
-- * task_apply_stage_events — одна транзакция на бизнес-действие. Логика
--   остаётся в Dart (она там покрыта тестами), сюда переезжает только
--   атомарность: список операций применяется целиком или не применяется вовсе.
-- * Триггер закрывает открытые интервалы при завершении этапа — в базе
--   16 интервалов, открытых навсегда, и 11 из них у людей, которые в
--   assignees есть. То есть дыра шире, чем баг с назначением.
-- * Очередь: слот «рабочее место + заказ + этап + группа» уникален, а строка
--   переживает пересборку маршрута — при удалении задачи она освобождается,
--   при появлении новой задачи того же слота прикрепляется к ней. Так ручной
--   порядок в МУПЗ не теряется и дубли завестись не могут.

begin;

-- 1. Общие помощники ---------------------------------------------------------

-- Разбор payload комментария. Текст комментария — свободная строка ('separate',
-- 'done', 'Начал(а) этап'), приводить её к jsonb напрямую нельзя: AND в SQL не
-- гарантирует порядок вычисления, и защита «сначала проверим type» падала бы
-- на реальных данных.
create or replace function public.task_json_payload(p_text text)
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

comment on function public.task_json_payload(text) is
  'jsonb из текста комментария задачи или NULL, если это не объект. Нужен '
  'потому, что в tasks.comments.text лежит и свободный текст, и JSON.';

-- Формат метки времени интервала — ровно тот, что пишет клиент
-- (DateTime.toUtc().toIso8601String()), иначе DateTime.parse на телефоне
-- прочитает её иначе, чем записал сервер.
create or replace function public.task_iso_utc(p_at timestamptz)
returns text
language sql
stable
as $function$
  select to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
$function$;

-- Индекс последнего НЕЗАКРЫТОГО интервала сотрудника (или любого, если
-- p_subject пуст). Возвращает 0-базовый индекс внутри массива comments.
create or replace function public.task_open_interval_index(
  p_comments jsonb,
  p_subject text
)
returns int
language plpgsql
immutable
as $function$
declare
  v_elem jsonb;
  v_ord int;
  v_payload jsonb;
  v_subject text;
  v_ts bigint;
  v_best_ts bigint := -1;
  v_best int := null;
begin
  for v_ord, v_elem in
    select (ord - 1)::int, value
      from jsonb_array_elements(public.task_comments_to_array(p_comments))
        with ordinality as t(value, ord)
  loop
    if coalesce(v_elem->>'type', '') <> 'time_event' then continue; end if;
    v_payload := public.task_json_payload(v_elem->>'text');
    if v_payload is null then continue; end if;
    if (v_payload->>'endTime') is not null then continue; end if;
    v_subject := coalesce(v_payload->>'subjectUserId', v_elem->>'userId', '');
    if coalesce(trim(p_subject), '') <> '' and v_subject <> p_subject then
      continue;
    end if;
    v_ts := public.task_comment_millis(v_elem->>'timestamp');
    if v_ts > v_best_ts then
      v_best_ts := v_ts;
      v_best := v_ord;
    end if;
  end loop;
  return v_best;
end
$function$;

-- 2. Атомарное применение событий этапа --------------------------------------
--
-- p_ops — упорядоченный массив операций, применяемых к comments/assignees
-- одной транзакцией:
--   {"op":"add_assignee","userId":"..."}
--   {"op":"remove_assignee","userId":"..."}
--   {"op":"claim_stage","userId":"..."}      -- сотрудник становится един. исполнителем
--   {"op":"comment","type":"start","text":"...","userId":"..."}
--   {"op":"close_interval","subject":"...","note":"..."}
--   {"op":"open_interval","subject":"...","type":"production","initiatedBy":"...",
--    "workplaceId":"...","participants":[...],"executionMode":"...",
--    "helperId":"...","note":"..."}
--
-- Ядро вынесено в ЧИСТУЮ функцию task_apply_ops: она ничего не читает и не
-- пишет, поэтому её поведение проверяется обычным select-ом, без тестовых
-- строк в боевых таблицах.
create or replace function public.task_apply_ops(
  p_task_id text,
  p_stage_id text,
  p_comments jsonb,
  p_assignees text[],
  p_ops jsonb,
  p_at timestamptz default null
)
returns jsonb
language plpgsql
stable
as $function$
declare
  v_comments jsonb := public.task_comments_to_array(p_comments);
  v_assignees text[] := coalesce(p_assignees, array[]::text[]);
  v_now timestamptz := coalesce(p_at, clock_timestamp());
  v_now_ms bigint;
  v_offset int := 0;
  v_op jsonb;
  v_kind text;
  v_user text;
  v_subject text;
  v_note text;
  v_type text;
  v_open int;
  v_payload jsonb;
  v_event jsonb;
  v_ts bigint;
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
      if v_user <> '' then
        v_assignees := array_remove(v_assignees, v_user);
      end if;

    elsif v_kind = 'claim_stage' then
      -- Пришедшая смена забирает этап себе. В совместном режиме кнопки
      -- доступны только assignees.first, поэтому просто дописать её в конец
      -- нельзя — она осталась бы без управления. Отработанное время прежней
      -- смены хранится в интервалах time_event и от состава исполнителей
      -- не зависит.
      v_user := trim(coalesce(v_op->>'userId', ''));
      if v_user <> '' then
        v_assignees := array[v_user];
      end if;

    elsif v_kind = 'comment' then
      v_ts := v_now_ms + v_offset;
      v_offset := v_offset + 1;
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', coalesce(nullif(trim(coalesce(v_op->>'id', '')), ''), v_ts::text),
        'type', coalesce(v_op->>'type', ''),
        'text', coalesce(v_op->>'text', ''),
        'userId', coalesce(v_op->>'userId', ''),
        'timestamp', v_ts
      ));

    elsif v_kind = 'close_interval' then
      v_subject := trim(coalesce(v_op->>'subject', ''));
      v_note := v_op->>'note';
      v_open := public.task_open_interval_index(v_comments, v_subject);
      if v_open is not null then
        v_payload := public.task_json_payload(v_comments->v_open->>'text')
          || jsonb_build_object('endTime', public.task_iso_utc(v_now));
        if v_note is not null then
          v_payload := v_payload || jsonb_build_object('note', v_note);
        end if;
        v_comments := jsonb_set(
          v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      end if;

    elsif v_kind = 'open_interval' then
      v_subject := trim(coalesce(v_op->>'subject', ''));
      v_type := coalesce(v_op->>'type', '');
      v_note := v_op->>'note';
      if v_subject = '' or v_type = '' then continue; end if;

      v_open := public.task_open_interval_index(v_comments, v_subject);
      if v_open is not null then
        v_payload := public.task_json_payload(v_comments->v_open->>'text');
        -- Повторное нажатие той же кнопки не плодит интервалы: клиентский
        -- recordTimeEvent ведёт себя так же, и расходиться им нельзя.
        if coalesce(v_payload->>'type', '') = v_type then
          continue;
        end if;
        v_payload := v_payload
          || jsonb_build_object('endTime', public.task_iso_utc(v_now));
        if v_note is not null then
          v_payload := v_payload || jsonb_build_object('note', v_note);
        end if;
        v_comments := jsonb_set(
          v_comments, array[v_open::text, 'text'], to_jsonb(v_payload::text));
      end if;

      v_ts := v_now_ms + v_offset;
      v_offset := v_offset + 1;
      -- Форма payload — ровно как у TaskTimeEvent.toMap() на клиенте:
      -- пустые поля не пишем, иначе разбор на телефоне увидит другой объект.
      v_event := jsonb_strip_nulls(jsonb_build_object(
        'type', v_type,
        'startTime', public.task_iso_utc(v_now),
        'initiatedBy', coalesce(v_op->>'initiatedBy', v_subject),
        'subjectUserId', v_subject,
        'taskId', p_task_id,
        'workplaceId', coalesce(v_op->>'workplaceId', p_stage_id),
        'participantsSnapshot', coalesce(v_op->'participants', '[]'::jsonb),
        'executionMode', v_op->>'executionMode',
        'helperId', v_op->>'helperId',
        'note', v_note
      ));
      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', v_ts::text || '-' || v_subject,
        'type', 'time_event',
        'text', v_event::text,
        'userId', v_subject,
        'timestamp', v_ts
      ));

    else
      raise exception 'Неизвестная операция этапа: %', v_kind;
    end if;
  end loop;

  -- Порядок как на клиенте: по метке времени, при равенстве — как пришли.
  select coalesce(jsonb_agg(value order by
           public.task_comment_millis(value->>'timestamp'), ord), '[]'::jsonb)
    into v_comments
    from jsonb_array_elements(v_comments) with ordinality as t(value, ord);

  return jsonb_build_object(
    'assignees', to_jsonb(v_assignees),
    'comments', v_comments
  );
end
$function$;

comment on function public.task_apply_ops(text, text, jsonb, text[], jsonb, timestamptz) is
  'Чистое применение операций этапа к паре (comments, assignees). Ничего не '
  'читает и не пишет — проверяется обычным select. Транзакцию и блокировку '
  'строки добавляет task_apply_stage_events.';

-- p_expect_assignee — необязательная проверка «сотрудник всё ещё на этапе»:
-- если за время диалога его сняли, действие не применяется.
create or replace function public.task_apply_stage_events(
  p_task_id text,
  p_ops jsonb,
  p_expect_assignee text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_task tasks%rowtype;
  v_result jsonb;
  v_assignees text[];
begin
  if coalesce(trim(p_task_id), '') = '' then
    raise exception 'task_id is required';
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

  v_result := public.task_apply_ops(
    p_task_id, v_task.stage_id, v_task.comments, v_assignees, p_ops);

  update tasks
     set comments = v_result->'comments',
         assignees = array(
           select jsonb_array_elements_text(v_result->'assignees'))
   where id::text = p_task_id;

  return v_result;
end
$function$;

comment on function public.task_apply_stage_events(text, jsonb, text) is
  'Применяет список событий этапа (назначения, комментарии, интервалы) одной '
  'транзакцией. Заменяет цепочку независимых запросов клиента, каждый из '
  'которых мог потеряться на сбойной сети и оставить действие наполовину '
  'выполненным: пересмену без записи shift_pause, старт без назначения.';

-- 3. Завершение этапа закрывает все открытые интервалы -----------------------
--
-- Триггером, а не в complete_task_stage: путей закрытия несколько
-- (complete_task_stage, complete_flex_printing_stage_with_paint_queue, ручная
-- правка статуса), а незакрытый интервал одинаково ядовит для аналитики —
-- он считается «до сих пор идёт» и растит часы сотруднику бесконечно.
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
    v_payload := public.task_json_payload(v_comments->v_open->>'text');
    v_payload := v_payload
      || jsonb_build_object('endTime', public.task_iso_utc(v_now))
      || jsonb_build_object('note', 'stage_completed');
    v_comments := jsonb_set(
      v_comments,
      array[v_open::text, 'text'],
      to_jsonb(v_payload::text)
    );
    v_guard := v_guard + 1;
    exit when v_guard > 500;
  end loop;

  new.comments := v_comments;
  return new;
end
$function$;

drop trigger if exists tasks_close_intervals_on_complete on public.tasks;
create trigger tasks_close_intervals_on_complete
  before insert or update of status on public.tasks
  for each row
  execute function public.tasks_close_intervals_on_complete();

comment on function public.tasks_close_intervals_on_complete() is
  'Закрывает незакрытые интервалы времени при переводе этапа в completed. '
  'Без него интервал остаётся открытым навсегда и аналитика считает его '
  'идущим до сих пор — в базе таких накопилось 16.';

-- 4. Очередь рабочих мест: один слот — одна строка ---------------------------

-- 4.1. Схлопываем существующие дубли. Выигрывает строка живой задачи; при
-- прочих равных — меньший номер (он ближе к тому, куда её ставил мастер).
with ranked as (
  select
    p.id,
    row_number() over (
      partition by p.workplace_id, p.order_id, p.stage_id,
                   coalesce(p.stage_group_key, '')
      order by
        (p.task_id is not null
          and exists (select 1 from public.tasks t where t.id::text = p.task_id)
        ) desc,
        p.queue_position asc nulls last,
        p.id asc
    ) as rn
  from public.workplace_queue_positions p
)
delete from public.workplace_queue_positions p
using ranked r
where p.id = r.id and r.rn > 1;

-- 4.2. Строки исчезнувших задач и закрытых заказов.
do $prune$
declare
  v_deleted integer;
begin
  v_deleted := public.prune_workplace_queue_positions();
  raise notice 'workplace_queue_positions: удалено строк-сирот %', v_deleted;
end
$prune$;

-- 4.3. Слот уникален независимо от того, заполнен task_id или нет.
-- Прежние два частичных индекса этого не давали: пара «строка с task_id +
-- строка с другим task_id» проходила обе проверки, и заказ получал два номера
-- в одной очереди.
drop index if exists public.workplace_queue_positions_stage_key;
create unique index if not exists workplace_queue_positions_slot_key
  on public.workplace_queue_positions (
    workplace_id, order_id, stage_id, coalesce(stage_group_key, '')
  );

comment on index public.workplace_queue_positions_slot_key is
  'Один номер очереди на пару «рабочее место + этап заказа». Без него показ и '
  'перестановка выбирали разные строки одного заказа, и поднять его в очереди '
  'было невозможно (ТОО Raw на Листорезке).';

-- 4.4. Строка очереди переживает пересборку маршрута.
--
-- OrderQueueSyncService удаляет и пересоздаёт задачи при правке заказа. Раньше
-- строка очереди оставалась висеть на удалённой задаче, а новая задача
-- получала вторую строку в хвосте. Теперь при удалении задачи строка
-- освобождается (task_id → null, номер сохраняется), а при появлении новой
-- задачи того же слота — прикрепляется к ней.
create or replace function public.workplace_queue_release_task()
returns trigger
language plpgsql
as $function$
begin
  update public.workplace_queue_positions
     set task_id = null,
         updated_at = now()
   where task_id = old.id::text;
  return old;
end
$function$;

drop trigger if exists tasks_release_queue_slot on public.tasks;
create trigger tasks_release_queue_slot
  after delete on public.tasks
  for each row
  execute function public.workplace_queue_release_task();

create or replace function public.workplace_queue_adopt_task()
returns trigger
language plpgsql
as $function$
begin
  update public.workplace_queue_positions
     set task_id = new.id::text,
         updated_at = now()
   where task_id is null
     and order_id = new.order_id::text
     and stage_id = new.stage_id
     and coalesce(stage_group_key, '')
         = coalesce(nullif(new.stage_group_key, ''), new.stage_id);
  return new;
end
$function$;

drop trigger if exists tasks_adopt_queue_slot on public.tasks;
create trigger tasks_adopt_queue_slot
  after insert on public.tasks
  for each row
  execute function public.workplace_queue_adopt_task();

comment on function public.workplace_queue_release_task() is
  'При удалении задачи освобождает её строку очереди вместо того, чтобы '
  'оставить ссылку на несуществующую задачу. Номер сохраняется — маршрут '
  'пересобирается, ручной порядок в МУПЗ остаётся.';

comment on function public.workplace_queue_adopt_task() is
  'Новая задача занимает свободный слот очереди своего этапа, а не создаёт '
  'вторую строку в хвосте.';

commit;
