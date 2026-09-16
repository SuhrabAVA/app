-- ПРЕДПРОСМОТР пересчёта долей на исторических совместных этапах.
--
-- Делает ровно то же, что `supabase/migrations/20260908_backfill_quantity_shares.sql`,
-- и в конце ОТКАТЫВАЕТ всё исключением. Ничего не сохраняет.
--
-- ОТЧЁТ ЕДЕТ В ТЕКСТЕ ИСКЛЮЧЕНИЯ, а не через RAISE NOTICE: SQL-редактор
-- Supabase показывает только ошибку, а notice глотает — первый вариант
-- скрипта отработал целиком, но пользователь не увидел ни строчки отчёта.
-- Заодно это гарантирует откат: сообщение и откат теперь одно и то же
-- событие, их нельзя разделить по недосмотру.
--
-- Итог печатается ПЕРВЫМ: длинное сообщение редактор может обрезать, и
-- обрезаться должны подробности, а не сводка.
--
-- Зачем предпросмотр вообще пишет в базу: доли считает
-- `recompute_task_quantity_shares`, а он читает `quantity_stage_total` из
-- самой строки задачи. Показать результат, не выполнив конвертацию, нельзя —
-- это был бы предпросмотр другого алгоритма, а не того, что применится.

do $preview$
declare
  -- Та же граница, что в миграции. Меняете здесь — поменяйте и там.
  -- Август: по отчёту по месяцам вся история — это август и сентябрь, и ни
  -- одна задача не пропускается из-за отсутствия интервалов.
  v_window_start timestamptz :=
    date_trunc('month', now()) - interval '1 month';

  -- Сколько задач расписывать подробно. Остальные попадут только в сводку.
  v_detail_limit int := 15;

  v_task record;
  v_comments jsonb;
  v_new jsonb;
  v_totals text[];
  v_row record;
  v_tasks int := 0;
  v_dropped int := 0;
  v_detail text := '';
  v_line text;
  v_stage_total numeric;
  v_helper record;
  v_owner text;
  v_workplace text;
  v_seg_end_ms bigint;
  v_restored int := 0;
begin
  if to_regprocedure('public.recompute_task_quantity_shares(text)') is null then
    raise exception using
      message = 'public.recompute_task_quantity_shares(text) is missing',
      hint = 'Сначала примените 20260821_quantity_share_rpc.sql и '
             '20260821_quantity_share_wiring.sql';
  end if;

  for v_task in
    select t.id::text as id,
           t.order_id::text as order_id,
           t.stage_id::text as stage_id,
           t.comments,
           coalesce(t.assignees, array[]::text[]) as assignees,
           coalesce(
             nullif(trim(coalesce(t.captured_by_workplace_id::text, '')), ''),
             t.stage_id::text
           ) as workplace_id
      from public.tasks t
     where t.comments is not null
       and exists (
         select 1
           from jsonb_array_elements(
                  public.task_comments_to_array(t.comments::jsonb)) c
          -- Отбор по quantity_stage_total, а НЕ по quantity_team_total:
          -- миграция 20260908_stage_total_for_history переименовала последний
          -- во всей истории, и старого типа в базе больше нет вовсе.
          -- Повторный прогон по уже обработанным задачам безвреден:
          -- recompute_task_quantity_shares идемпотентен, машинные копии там
          -- уже удалены, а восстановление интервалов пропускает тех, у кого
          -- интервал есть.
          where c->>'type' = 'quantity_stage_total'
            and coalesce(trim(c->>'text'), '') <> ''
            and to_timestamp(
                  public.task_comment_millis(c->>'timestamp') / 1000.0
                ) >= v_window_start
       )
       and exists (
         select 1
           from jsonb_array_elements(
                  public.task_comments_to_array(t.comments::jsonb)) c
          where c->>'type' = 'joined'
       )
       and exists (
         select 1
           from jsonb_array_elements(
                  public.task_comments_to_array(t.comments::jsonb)) c
          where c->>'type' = 'time_event'
            and public.task_quantity_payload(c->>'text')->>'type' = 'production'
       )
     order by t.id
  loop
    v_comments := public.task_comments_to_array(v_task.comments::jsonb);
    v_owner := coalesce(v_task.assignees[1], '');
    v_workplace := v_task.workplace_id;
    v_tasks := v_tasks + 1;

    -- Тиражом считается и доля НА ВЛАДЕЛЬЦЕ: старая complete_task_stage
    -- писала владельцу quantity_team_total, а quantity_share — только
    -- помощникам. Значит quantity_share на владельце оставлен пересменой и
    -- является тиражом СЕГМЕНТА.
    select coalesce(array_agg(distinct c->>'text'), array[]::text[])
      into v_totals
      from jsonb_array_elements(v_comments) c
     where coalesce(trim(c->>'text'), '') <> ''
       and (
         c->>'type' in ('quantity_team_total', 'quantity_stage_total')
         or (
           c->>'type' = 'quantity_share'
           and trim(coalesce(c->>'userId', '')) = v_owner
           and v_owner <> ''
           and coalesce(
                 public.task_quantity_payload(c->>'text')->>'generated',
                 '') <> 'true'
           and coalesce(
                 trim(public.task_quantity_payload(c->>'text')->>'edited_by'),
                 '') = ''
         )
       );


    if v_tasks <= v_detail_limit then
      -- Сумма ВСЕХ сегментов: и закрытия, и пересмен.
      select sum(public.task_quantity_value(t))
        into v_stage_total
        from unnest(v_totals) t;

      v_detail := v_detail
        || format(E'\n[%s] заказ %s, этап %s, тираж %s\n',
                  v_tasks, v_task.order_id, v_task.stage_id,
                  coalesce(v_stage_total, 0));

      v_line := '';
      for v_row in
        select c->>'userId' as uid,
               sum(public.task_quantity_value(c->>'text')) as qty
          from jsonb_array_elements(v_comments) c
         where c->>'type' = 'quantity_share'
         group by 1
         order by 1
      loop
        v_line := v_line || format('    %s = %s%s', v_row.uid, v_row.qty,
                                   E'\n');
      end loop;
      v_detail := v_detail || '  БЫЛО:' || E'\n'
        || coalesce(nullif(v_line, ''), E'    (долей нет)\n');
    end if;

    select coalesce(jsonb_agg(x.c order by x.ord), '[]'::jsonb)
      into v_new
      from (
        select
          a.ord,
          case
            when a.c->>'type' = 'quantity_team_total'
              then jsonb_set(a.c, '{type}', '"quantity_stage_total"'::jsonb)
            -- Пересмена владельца — тираж сегмента, а не личная доля.
            when a.c->>'type' = 'quantity_share'
                 and trim(coalesce(a.c->>'userId', '')) = v_owner
                 and v_owner <> ''
                 and coalesce(
                       public.task_quantity_payload(a.c->>'text')
                         ->>'generated', '') <> 'true'
                 and coalesce(
                       trim(public.task_quantity_payload(a.c->>'text')
                         ->>'edited_by'), '') = ''
              then jsonb_set(a.c, '{type}', '"quantity_stage_total"'::jsonb)
            else a.c
          end as c
        from jsonb_array_elements(v_comments) with ordinality as a(c, ord)
        where not (
          a.c->>'type' = 'quantity_share'
          -- Владельца не трогаем: его запись выше стала тиражом сегмента.
          and trim(coalesce(a.c->>'userId', '')) <> v_owner
          and coalesce(
                public.task_quantity_payload(a.c->>'text')->>'generated',
                '') <> 'true'
          and coalesce(
                trim(public.task_quantity_payload(a.c->>'text')->>'edited_by'),
                '') = ''
          and a.c->>'text' = any(v_totals)
        )
      ) x;

    v_dropped := v_dropped
      + (jsonb_array_length(v_comments) - jsonb_array_length(v_new));

    v_comments := v_new;

    -- Восстановление потерянных интервалов помощников.
    -- БЛОК ПРОДУБЛИРОВАН в supabase/migrations/20260908_backfill_quantity_shares.sql
    -- — правите здесь, поправьте и там, иначе предпросмотр покажет не то,
    -- что применится.
    for v_helper in
      select trim(e->>'userId') as uid,
             min(public.task_comment_millis(e->>'timestamp')) as joined_ms
        from jsonb_array_elements(v_comments) e
       where e->>'type' = 'joined'
         and coalesce(trim(e->>'userId'), '') <> ''
       group by 1
    loop
      if exists (
        select 1
          from jsonb_array_elements(v_comments) e
         where e->>'type' = 'time_event'
           and public.task_quantity_payload(e->>'text')->>'type' = 'production'
           and trim(coalesce(
                 public.task_quantity_payload(e->>'text')->>'subjectUserId',
                 '')) = v_helper.uid
      ) then
        continue;
      end if;

      select min(public.task_comment_millis(e->>'timestamp'))
        into v_seg_end_ms
        from jsonb_array_elements(v_comments) e
       where e->>'type' = 'quantity_stage_total'
         and public.task_comment_millis(e->>'timestamp') > v_helper.joined_ms;

      if v_seg_end_ms is null then
        continue;
      end if;

      v_comments := v_comments || jsonb_build_array(jsonb_build_object(
        'id', gen_random_uuid()::text,
        'type', 'time_event',
        'userId', v_helper.uid,
        'timestamp', v_helper.joined_ms,
        'text', (jsonb_build_object(
          'type', 'production',
          'startTime', to_char(
            to_timestamp(v_helper.joined_ms / 1000.0) at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'endTime', to_char(
            to_timestamp(v_seg_end_ms / 1000.0) at time zone 'UTC',
            'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
          'initiatedBy', v_owner,
          'subjectUserId', v_helper.uid,
          'taskId', v_task.id,
          'workplaceId', v_workplace,
          'participantsSnapshot', '[]'::jsonb,
          'reconstructed', true,
          'note', 'Интервал восстановлен бэкофиллом: помощника добавили в '
                  'уже идущий этап, старый клиент интервал не открывал'
        ))::text
      ));
      v_restored := v_restored + 1;
    end loop;

    update public.tasks set comments = v_comments where id::text = v_task.id;
    perform public.recompute_task_quantity_shares(v_task.id);

    if v_tasks <= v_detail_limit then
      v_line := '';
      for v_row in
        select c->>'userId' as uid,
               sum(public.task_quantity_value(c->>'text')) as qty
          from public.tasks t,
               jsonb_array_elements(
                 public.task_comments_to_array(t.comments::jsonb)) c
         where t.id::text = v_task.id
           and c->>'type' = 'quantity_share'
         group by 1
         order by 1
      loop
        v_line := v_line || format('    %s = %s%s', v_row.uid, v_row.qty,
                                   E'\n');
      end loop;
      v_detail := v_detail || '  СТАНЕТ:' || E'\n'
        || coalesce(nullif(v_line, ''), E'    (долей нет)\n');
    end if;
  end loop;

  -- Сводка первой: если редактор обрежет сообщение, обрежутся подробности.
  --
  -- Собираем concat_ws(chr(10), ...), а НЕ склейкой соседних литералов:
  -- PostgreSQL склеивает только простые строки, а с повторным префиксом E'
  -- на продолжении даёт syntax error (проверено на живой базе). Здесь нет
  -- ни escape-строк, ни склейки — ломаться нечему.
  v_line := concat_ws(chr(10),
    'ПРЕДПРОСМОТР — ИЗМЕНЕНИЯ ОТКАЧЕНЫ, ЭТО НЕ ОШИБКА',
    format('Окно: с %s', v_window_start),
    format('Задач под пересчёт: %s', v_tasks),
    format('Машинных копий долей к удалению: %s', v_dropped),
    format('Потерянных интервалов к восстановлению: %s', v_restored),
    format('Подробно показано задач: %s', least(v_tasks, v_detail_limit)),
    v_detail);

  raise exception '%', v_line;
end
$preview$;
