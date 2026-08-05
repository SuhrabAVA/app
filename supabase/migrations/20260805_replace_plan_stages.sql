-- Атомарное сохранение очереди этапов заказа.
--
-- СТАТУС НА МОМЕНТ КОММИТА
-- Функция применена в базе, но Dart на неё ещё НЕ переключён: приложение
-- пишет очередь старым путём (OrderQueueSyncService.sync — отдельные
-- удаления, парковка, обновления, вставки без транзакции). То есть проблемы,
-- описанные ниже, в проде пока воспроизводятся; функция лежит наготове.
-- Доводка инварианта step_no также не сделана.
--
-- ЗАЧЕМ
-- Клиент сохранял очередь последовательностью отдельных запросов
-- (OrderQueueSyncService.sync): удаления, «парковка» в отрицательные seq,
-- обновления, вставки. Три следствия:
--   1. seq для вставок считался только по новой очереди и не учитывал seq,
--      занятые защищёнными этапами → нарушение UNIQUE (plan_id, seq), код 23505;
--   2. парковка включалась лишь при двух и более обновлениях, а вставки
--      не парковались вообще;
--   3. транзакции не было: падение на фазе вставок оставляло уже применённые
--      удаления и обновления, план — в наполовину изменённом состоянии, а при
--      обрыве после парковки строки навсегда оставались с отрицательным seq.
-- В проде в зоне риска 74 плана из 139.
--
-- Здесь та же парковка, но внутри одной транзакции: промежуточное состояние
-- снаружи не видно, а при любой ошибке всё откатывается целиком. Схему
-- таблицы функция НЕ меняет — в частности, констрейнт остаётся
-- NOT DEFERRABLE, чтобы будущий `on conflict (plan_id, seq)` продолжал
-- находить целевой индекс (у отложенных констрейнтов Postgres этого не умеет).
--
-- ДВА ПИСАТЕЛЯ prod_plan_stages — РАЗДЕЛЕНИЕ ПО ПОЛЯМ
-- Эту таблицу пишут двое, и они НЕ пересекаются по колонкам:
--   * replace_plan_stages (эта функция) — состав строк, seq, step_no, name.
--     Отвечает за ПЛАН: какие этапы есть и в каком порядке.
--   * advance_order_after_task_completion — status, finished_at.
--     Отвечает за ФАКТ: что уже отработано. Вызывается из
--     complete_flex_printing_stage_with_paint_queue и complete_task_stage.
-- Не переносите сюда работу со status и не трогайте seq/step_no там —
-- разделение по полям и есть то, что позволяет им сосуществовать.
-- Замечание: advance_order_after_task_completion содержит ветку записи в
-- prod_plan_stages.completed_at, но такой колонки в таблице нет (23 колонки,
-- completed_at среди них отсутствует). Ветка отсеивается собственной проверкой
-- по information_schema и никогда не исполняется — искать её не нужно.
--
-- ЗАЩИТА ОТ ГОНКИ
-- Опасный сценарий: между чтением статусов и удалением ожидающих строк
-- параллельная advance_order_after_task_completion переводит строку
-- waiting → completed. Мы бы удалили только что отработанный этап.
-- Защита — SELECT ... FOR UPDATE по всем строкам плана в начале транзакции:
-- он блокирует параллельное обновление до COMMIT, поэтому снимок статусов
-- остаётся действительным до конца работы. Взаимоблокировка невозможна:
-- advance_order_after_task_completion берёт сначала tasks, потом
-- prod_plan_stages, а эта функция к tasks не обращается вовсе, цикла нет.
-- Альтернатива «перечитать статусы перед удалением» отвергнута: она сужает
-- окно, но не закрывает его, и требует повторной проверки ещё и перед вставкой.
--
-- ПОЧЕМУ НЕ delete + insert ЦЕЛИКОМ
-- На prod_plan_stages.id ссылаются prod_stage_history, prod_stage_comments и
-- prod_stage_files — все с ON DELETE CASCADE. Сегодня по ожидающим этапам там
-- пусто (847 записей истории, все по отработанным), поэтому массовое удаление
-- сошло бы с рук. Но если историю начнут писать и для waiting, delete+insert
-- молча её уничтожит. Поэтому здесь трёхстороннее слияние: совпавшие строки
-- ОБНОВЛЯЮТСЯ и сохраняют свой id, удаляются только исчезнувшие.
--
-- СОПОСТАВЛЕНИЕ СТРОК
-- Ключ — (нормализованный stage_group_key, stage_id), где нормализация та же,
-- что в advance_order_after_task_completion: coalesce(nullif(trim(key),''),
-- stage_id). В проде пустых stage_group_key нет ни одного (751 строка), так
-- что откат на stage_id — только страховка.
--
-- SECURITY DEFINER
-- Приложение работает под общим Supabase-пользователем, и INVOKER формально
-- хватило бы. DEFINER взят, чтобы инвариант «seq уникален и согласован»
-- держался независимо от того, какие политики появятся у таблицы позже.
-- Обязательные спутники: явный search_path и снятие права выполнения с public.

create or replace function public.replace_plan_stages(
  p_plan_id uuid,
  p_stages jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_item        jsonb;
  v_idx         integer := 0;
  v_stage_id    text;
  v_group_key   text;
  v_name        text;
  v_step_no     integer;
  v_next_seq    integer := 0;
  v_park_base   integer;
  v_used_seq    integer[] := '{}';
  v_deleted     integer := 0;
  v_inserted    integer := 0;
  v_updated     integer := 0;
  v_protected   jsonb := '[]'::jsonb;
  v_row         record;
begin
  ---------------------------------------------------------------------------
  -- 1. Валидация входа. Тексты читает оператор в снекбаре, не разработчик.
  ---------------------------------------------------------------------------
  if p_plan_id is null then
    raise exception 'Не удалось сохранить очередь: не указан план заказа.'
      using errcode = '22023';
  end if;

  if p_stages is null or jsonb_typeof(p_stages) <> 'array' then
    raise exception 'Не удалось сохранить очередь: список этапов повреждён.'
      using errcode = '22023';
  end if;

  if jsonb_array_length(p_stages) = 0 then
    raise exception
      'Не удалось сохранить очередь: список этапов пуст. Соберите очередь заново.'
      using errcode = '22023';
  end if;

  if not exists (select 1 from prod_plans where id = p_plan_id) then
    raise exception
      'Не удалось сохранить очередь: план заказа не найден. Обновите список заказов.'
      using errcode = '23503';
  end if;

  -- Разбираем вход во временную структуру и проверяем каждый элемент.
  -- drop if exists — на случай двух вызовов в одной транзакции: ON COMMIT DROP
  -- срабатывает только на коммите, и второй CREATE иначе упал бы.
  drop table if exists _incoming;
  create temporary table _incoming (
    ord        integer primary key,
    stage_id   text    not null,
    group_key  text    not null,
    name       text    not null,
    step_no    integer not null,
    match_id   uuid,
    assigned   integer
  ) on commit drop;

  for v_item in select value from jsonb_array_elements(p_stages) loop
    v_idx := v_idx + 1;

    v_stage_id := nullif(btrim(coalesce(v_item->>'stage_id', '')), '');
    if v_stage_id is null then
      raise exception
        'Не удалось сохранить очередь: у этапа № % не указано рабочее место.', v_idx
        using errcode = '22023';
    end if;

    v_group_key := coalesce(
      nullif(btrim(coalesce(v_item->>'stage_group_key', '')), ''),
      v_stage_id
    );

    v_name := coalesce(nullif(btrim(coalesce(v_item->>'name', '')), ''), v_stage_id);

    begin
      v_step_no := coalesce((v_item->>'step_no')::integer, v_idx);
    exception when others then
      raise exception
        'Не удалось сохранить очередь: у этапа «%» неверный номер шага (%).',
        v_name, v_item->>'step_no' using errcode = '22023';
    end;

    if v_step_no <= 0 then
      raise exception
        'Не удалось сохранить очередь: у этапа «%» номер шага должен быть больше нуля.',
        v_name using errcode = '22023';
    end if;

    insert into _incoming(ord, stage_id, group_key, name, step_no)
    values (v_idx, v_stage_id, v_group_key, v_name, v_step_no);
  end loop;

  -- Дубль проверяется по ПАРЕ (группа, рабочее место) — это и есть
  -- идентичность строки. Одно и то же РМ на разных шагах законно: например,
  -- «Ручка-склейка ручная» объявлена в билдере и в flat_handle_group, и в
  -- twisted_handle_group. Сегодня они взаимоисключающие, но проверка по
  -- одному stage_id запретила бы это без причины.
  if exists (
    select 1 from _incoming group by group_key, stage_id having count(*) > 1
  ) then
    raise exception
      'Не удалось сохранить очередь: одно и то же рабочее место указано дважды на одном шаге.'
      using errcode = '22023';
  end if;

  ---------------------------------------------------------------------------
  -- 2. Блокируем все строки плана — снимок статусов не изменится до COMMIT
  ---------------------------------------------------------------------------
  perform 1
    from prod_plan_stages
   where plan_id = p_plan_id
   for update;

  ---------------------------------------------------------------------------
  -- 3. Сопоставляем существующие строки с новой очередью
  ---------------------------------------------------------------------------
  update _incoming inc
     set match_id = s.id
    from prod_plan_stages s
   where s.plan_id = p_plan_id
     and coalesce(nullif(btrim(coalesce(s.stage_group_key, '')), ''), s.stage_id)
         = inc.group_key
     and s.stage_id = inc.stage_id;

  ---------------------------------------------------------------------------
  -- 4. Конфликты: защищённые строки, которые новая очередь двигает или убирает.
  --    Сами строки при этом остаются нетронутыми — меняется только ответ.
  ---------------------------------------------------------------------------
  for v_row in
    select s.stage_id, s.stage_group_key, s.name, s.seq, s.step_no,
           s.status::text as status,
           inc.step_no as requested_step_no,
           (inc.ord is null) as removed
      from prod_plan_stages s
      left join _incoming inc on inc.match_id = s.id
     where s.plan_id = p_plan_id
       and s.status <> 'waiting'
     order by s.step_no nulls last, s.seq
  loop
    if v_row.removed then
      v_protected := v_protected || jsonb_build_array(jsonb_build_object(
        'stage_id', v_row.stage_id,
        'stage_group_key', v_row.stage_group_key,
        'name', v_row.name,
        'seq', v_row.seq,
        'step_no', v_row.step_no,
        'status', v_row.status,
        'requested_step_no', null,
        'reason', 'removed'
      ));
    elsif v_row.requested_step_no is distinct from v_row.step_no then
      v_protected := v_protected || jsonb_build_array(jsonb_build_object(
        'stage_id', v_row.stage_id,
        'stage_group_key', v_row.stage_group_key,
        'name', v_row.name,
        'seq', v_row.seq,
        'step_no', v_row.step_no,
        'status', v_row.status,
        'requested_step_no', v_row.requested_step_no,
        'reason', 'moved'
      ));
    end if;
  end loop;

  ---------------------------------------------------------------------------
  -- 5. Удаляем ожидающие строки, которых больше нет в очереди.
  --    Защищённые не трогаем никогда — фильтр status = 'waiting'.
  ---------------------------------------------------------------------------
  with removed as (
    delete from prod_plan_stages s
     where s.plan_id = p_plan_id
       and s.status = 'waiting'
       and not exists (select 1 from _incoming inc where inc.match_id = s.id)
    returning 1
  )
  select count(*) into v_deleted from removed;

  ---------------------------------------------------------------------------
  -- 6. Парковка: сдвигаем все выжившие ожидающие строки ниже минимального seq
  --    плана. Диапазон заведомо свободен, поэтому промежуточных коллизий нет
  --    и отложенный констрейнт не нужен. Видно это состояние только внутри
  --    транзакции: при ошибке всё откатится.
  ---------------------------------------------------------------------------
  select least(coalesce(min(seq), 0), 0) - 1
    into v_park_base
    from prod_plan_stages
   where plan_id = p_plan_id;

  with parked as (
    select s.id, row_number() over (order by s.seq) as rn
      from prod_plan_stages s
     where s.plan_id = p_plan_id
       and s.status = 'waiting'
  )
  update prod_plan_stages s
     set seq = v_park_base - parked.rn + 1
    from parked
   where s.id = parked.id;

  ---------------------------------------------------------------------------
  -- 7. Раздаём финальные seq: защищённые сохраняют свои, остальные получают
  --    свободные по возрастанию в порядке новой очереди. Так порядок по seq
  --    перестаёт расходиться с порядком по step_no.
  ---------------------------------------------------------------------------
  select coalesce(array_agg(s.seq), '{}')
    into v_used_seq
    from prod_plan_stages s
   where s.plan_id = p_plan_id
     and s.status <> 'waiting';

  for v_row in
    select inc.*
      from _incoming inc
      left join prod_plan_stages s
        on s.id = inc.match_id and s.status <> 'waiting'
     where s.id is null
     order by inc.ord
  loop
    loop
      v_next_seq := v_next_seq + 1;
      exit when not (v_next_seq = any (v_used_seq));
    end loop;

    update _incoming set assigned = v_next_seq where ord = v_row.ord;
  end loop;

  ---------------------------------------------------------------------------
  -- 8. Обновляем сохранившиеся ожидающие строки и вставляем новые
  ---------------------------------------------------------------------------
  for v_row in select * from _incoming where assigned is not null order by ord loop
    if v_row.match_id is not null then
      update prod_plan_stages
         set seq             = v_row.assigned,
             step_no         = v_row.step_no,
             name            = v_row.name,
             stage_group_key = v_row.group_key,
             updated_at      = now()
       where id = v_row.match_id;
      v_updated := v_updated + 1;
    else
      insert into prod_plan_stages(
        plan_id, stage_id, stage_group_key, name, seq, step_no, status
      )
      values (
        p_plan_id, v_row.stage_id, v_row.group_key, v_row.name,
        v_row.assigned, v_row.step_no, 'waiting'
      );
      v_inserted := v_inserted + 1;
    end if;
  end loop;

  return jsonb_build_object(
    'plan_id',   p_plan_id,
    'deleted',   v_deleted,
    'inserted',  v_inserted,
    'updated',   v_updated,
    'protected', v_protected
  );
end;
$function$;

comment on function public.replace_plan_stages(uuid, jsonb) is
  'Атомарно приводит очередь этапов плана к переданной. Защищённые этапы '
  '(status <> waiting) не двигает и не удаляет, а возвращает списком в поле '
  'protected. Отвечает за состав, seq и step_no; status и finished_at пишет '
  'advance_order_after_task_completion.';

revoke execute on function public.replace_plan_stages(uuid, jsonb) from public;
grant  execute on function public.replace_plan_stages(uuid, jsonb) to authenticated;
