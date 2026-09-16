-- Пересчёт долей на исторических совместных этапах.
--
-- ЗАЧЕМ. Расчёт долей по отработанному времени написан 21.08.2026, но обвязка
-- (`20260821_quantity_share_wiring.sql`) применена не была, и до сих пор
-- работала старая `complete_task_stage`: КАЖДОМУ помощнику писалось полное Q
-- (`quantity_share`), владельцу — `quantity_team_total`. Помощник, пришедший
-- на последний час пятичасового этапа, получал столько же, сколько
-- отработавший смену, а владелец не получал личной доли вовсе.
--
-- ПОРЯДОК. Применяется ПОСЛЕ обвязки. Обвязка чинит только будущие
-- завершения; историю она не трогает, потому что `recompute_task_quantity_shares`
-- нарезает сегменты по `quantity_stage_total`, а в старых задачах их нет —
-- там `quantity_team_total`, и пересчёт отработал бы вхолостую.
--
-- ЧТО ДЕЛАЕТ, по задаче:
--   1. `quantity_team_total` → `quantity_stage_total` (появляется сегмент);
--   2. удаляет машинные копии долей;
--   3. ВОССТАНАВЛИВАЕТ потерянные интервалы помощников (см. ниже);
--   4. зовёт `recompute_task_quantity_shares` — тот пишет доли по времени.
--
-- ЧТО УДАЛЯЕТСЯ — и только это. Запись сносится, если выполнены ВСЕ условия:
--   * тип `quantity_share`;
--   * НЕ помечена `generated` (наши собственные доли пересчёт снесёт сам);
--   * НЕ помечена `edited_by` (правки техлида обязаны пережить пересчёт);
--   * её текст СОВПАДАЕТ с текстом тиража этой же задачи.
-- Последнее — подпись старой функции: она копировала `p_quantity_done` в долю
-- каждому помощнику дословно. Доля, введённая руками и не равная тиражу, под
-- критерий не попадает и остаётся на месте.
--
-- ВОССТАНОВЛЕНИЕ ИНТЕРВАЛОВ. Пересчёт делит тираж по интервалам `production`,
-- и участник без них получил бы НОЛЬ. Проверка на боевых данных нашла такой
-- случай: помощник присоединился к этапу за 20 минут до закрытия, и у него
-- нет ни одного интервала — ни production, ни паузы. Это известная дыра
-- старого клиента: помощнику, добавленному в УЖЕ ИДУЩИЙ этап, интервал не
-- открывался, пока основной исполнитель не сделает следующее действие. Её
-- закрыли позже (`decideHelperInterval`), но в исторических данных она
-- осталась, и без починки пересчёт отобрал бы у человека всю смену.
--
-- Поэтому такому участнику восстанавливается ровно тот интервал, который
-- завёл бы сегодняшний клиент: от отметки `joined` до конца его сегмента.
-- Это не выдуманные данные, а то же правило задним числом. Записи помечены
-- `"reconstructed": true` — их видно и можно отличить от настоящих.
--
-- Восстановление НЕ трогает тех, у кого интервалы есть: у них всё считается
-- по факту.
--
-- ОТКАТА НЕТ. Сначала прогоните `scripts/preview_quantity_share_backfill.sql`.

begin;

do $backfill$
declare
  -- Граница окна.
  --
  -- Август: отчёт `scripts/report_backfill_scope_by_month.sql` показал, что
  -- вся история совместных этапов — это август и сентябрь, и НИ ОДНА задача
  -- не пропускается из-за отсутствия интервалов. Значит брать можно всё.
  --
  -- Сентябрь попадёт в окно повторно, и это безвредно:
  -- `recompute_task_quantity_shares` идемпотентен, машинные копии там уже
  -- удалены, а восстановление интервалов пропускает тех, у кого интервал
  -- уже есть.
  v_window_start timestamptz :=
    date_trunc('month', now()) - interval '1 month';

  v_task record;
  v_helper record;
  v_comments jsonb;
  v_new jsonb;
  v_totals text[];
  v_owner text;
  v_workplace text;
  v_seg_end_ms bigint;
  v_tasks int := 0;
  v_dropped int := 0;
  v_restored int := 0;
  v_before int;
begin
  if to_regprocedure('public.recompute_task_quantity_shares(text)') is null then
    raise exception using
      message = 'public.recompute_task_quantity_shares(text) is missing',
      hint = 'Сначала примените 20260821_quantity_share_rpc.sql и '
             '20260821_quantity_share_wiring.sql';
  end if;

  for v_task in
    select t.id::text as id,
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
    v_before := jsonb_array_length(v_comments);
    v_owner := coalesce(v_task.assignees[1], '');
    v_workplace := v_task.workplace_id;

    -- 1-2. Конвертация тиражей и снос машинных копий долей.
    --
    -- Тиражом считается и доля НА ВЛАДЕЛЬЦЕ: старая `complete_task_stage`
    -- писала владельцу `quantity_team_total`, а `quantity_share` — только
    -- помощникам. Значит `quantity_share` на владельце написан не ею, а
    -- пересменой: инициатор фиксирует сделанное к моменту смены. Это тираж
    -- СЕГМЕНТА (см. `stage_quantity_records`), и он тоже идёт в факт заказа.
    --
    -- Найдено предпросмотром: заказ df004332 — 9798 на пересмене и 11833 при
    -- закрытии. Не разделив сегменты, пересчёт дописал бы владельцу долю
    -- поверх его же 9798 и выдал 11776 вместо ~1978.
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

    v_dropped := v_dropped + (v_before - jsonb_array_length(v_new));
    v_comments := v_new;

    -- 3. Восстановление потерянных интервалов.
    for v_helper in
      select trim(e->>'userId') as uid,
             min(public.task_comment_millis(e->>'timestamp')) as joined_ms
        from jsonb_array_elements(v_comments) e
       where e->>'type' = 'joined'
         and coalesce(trim(e->>'userId'), '') <> ''
       group by 1
    loop
      -- Интервалы есть — считаем по факту, ничего не выдумываем.
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

      -- Конец его сегмента — ближайший тираж ПОСЛЕ присоединения.
      select min(public.task_comment_millis(e->>'timestamp'))
        into v_seg_end_ms
        from jsonb_array_elements(v_comments) e
       where e->>'type' = 'quantity_stage_total'
         and public.task_comment_millis(e->>'timestamp') > v_helper.joined_ms;

      -- Присоединился после последнего тиража — работы за ним не числится.
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

    update public.tasks
       set comments = v_comments
     where id::text = v_task.id;

    -- 4. Доли по времени. Функция идемпотентна.
    perform public.recompute_task_quantity_shares(v_task.id);

    v_tasks := v_tasks + 1;
  end loop;

  raise notice 'Задач: %, копий удалено: %, интервалов восстановлено: %',
    v_tasks, v_dropped, v_restored;
end
$backfill$;

commit;

-- Проверка после применения: её редактор покажет таблицей (RAISE NOTICE он
-- глотает). Ожидаемо: «осталось со старым тиражом» = 0.
--
-- Окно продублировано из DO-блока выше — правите там, поправьте и здесь.
with scope as (
  select t.id::text as task_id,
         public.task_comments_to_array(t.comments::jsonb) as c
    from public.tasks t
   where t.comments is not null
),
flags as (
  select s.task_id,
         exists (select 1 from jsonb_array_elements(s.c) e
                  where e->>'type' = 'quantity_stage_total'
                    and to_timestamp(
                          public.task_comment_millis(e->>'timestamp') / 1000.0
                        ) >= date_trunc('month', now())) as has_stage_total,
         exists (select 1 from jsonb_array_elements(s.c) e
                  where e->>'type' = 'quantity_team_total'
                    and to_timestamp(
                          public.task_comment_millis(e->>'timestamp') / 1000.0
                        ) >= date_trunc('month', now())) as has_team_total,
         exists (select 1 from jsonb_array_elements(s.c) e
                  where e->>'type' = 'quantity_share'
                    and public.task_quantity_payload(e->>'text')->>'generated'
                        = 'true') as has_generated,
         exists (select 1 from jsonb_array_elements(s.c) e
                  where e->>'type' = 'time_event'
                    and public.task_quantity_payload(e->>'text')
                        ->>'reconstructed' = 'true') as has_restored,
         exists (select 1 from jsonb_array_elements(s.c) e
                  where e->>'type' = 'joined') as is_joint
    from scope s
)
select
  count(*) filter (where has_stage_total and is_joint) as "совместных с тиражом",
  count(*) filter (where has_generated)                as "с долями по времени",
  count(*) filter (where has_restored)                 as "с восстановленным временем",
  count(*) filter (where has_team_total and is_joint)  as "осталось со старым тиражом"
from flags;
