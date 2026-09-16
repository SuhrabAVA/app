-- ============================================================================
-- Целостность данных, шаг 3: личные доли у этапов с одним тиражом (2026-09-14)
--
-- ПРИМЕНЯТЬ ПОСЛЕ шага 2: пересчёт делит тираж по интервалам времени, а
-- открытый интервал считается идущим «до сих пор».
--
-- Что чинит
-- ---------
-- 189 закрытых этапов (78 — август, 111 — 1–8 сентября) хранят только тираж
-- этапа (quantity_stage_total) и ни одной личной записи. Аналитика тираж людям
-- не засчитывает (TaskAnalyticsMapper пропускает этот тип), поэтому выработка
-- и сдельная этих сотрудников пропали.
--
-- Причина — три шага, каждый верный по отдельности:
-- 1. Старая complete_task_stage в совместном режиме писала ВЛАДЕЛЬЦУ
--    quantity_team_total, даже если он работал один (клиент всегда передаёт
--    бригаду, в которой есть он сам), и аналитика считала это его выработкой.
-- 2. 20260908_stage_total_for_history переименовала quantity_team_total в
--    quantity_stage_total во всей истории — тираж стал «ничьим».
-- 3. 20260908_backfill_quantity_shares пересчитала доли только у задач с
--    отметкой joined, то есть с помощниками. Одиночные этапы остались без долей.
--
-- Та же дыра открыта и сейчас: одиночное завершение (complete_task_stage без
-- бригады) не запускает расчёт долей, даже если на этапе была пересмена и её
-- тираж лежит записью quantity_stage_total. Уходящий на пересмене личного
-- количества не получает.
--
-- Что делает миграция
-- -------------------
-- 1. complete_task_stage: доли считаются всегда, когда в задаче есть тираж
--    отрезка, а не только в совместном режиме.
-- 2. Пересчёт долей у завершённых задач, где тираж есть, а личных записей нет.
--    recompute_task_quantity_shares идемпотентна и трогает только свои
--    записи (generated), ручные правки переживают пересчёт.
-- ============================================================================

begin;

-- ─── 1. Доли при любом завершении с тиражом отрезка ─────────────────────────

do $patch$
declare
  v_sig constant regprocedure :=
    'public.complete_task_stage(text,text,text,text,text,text,jsonb,text)'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_anchor constant text := 'if v_needs_shares then';
  v_prefix constant text :=
    'if not v_needs_shares and exists (select 1 from jsonb_array_elements(v_comments) c '
    || 'where c->>''type'' = ''quantity_stage_total'') then '
    || 'v_needs_shares := true; '
    || 'end if; ';
  v_count int;
begin
  if position(v_prefix in v_def) > 0 then
    raise notice 'complete_task_stage уже пропатчена — пропуск';
    return;
  end if;

  v_count := (length(v_def) - length(replace(v_def, v_anchor, '')))
             / length(v_anchor);
  if v_count <> 1 then
    raise exception 'Шаблон v_needs_shares найден % раз(а) вместо 1 — '
      'функция изменилась, миграцию нужно пересобрать', v_count;
  end if;

  v_def := replace(v_def, v_anchor, v_prefix || v_anchor);
  execute v_def;
end
$patch$;

-- ─── 2. Пересчёт истории ────────────────────────────────────────────────────

do $recompute$
declare
  v_task_id text;
begin
  for v_task_id in
    select t.id::text
      from public.tasks t
     where t.status = 'completed'
       and exists (
         select 1
           from jsonb_array_elements(public.task_comments_to_array(t.comments)) c
          where c->>'type' = 'quantity_stage_total'
            and public.task_quantity_value(c->>'text') > 0
       )
       and not exists (
         select 1
           from jsonb_array_elements(public.task_comments_to_array(t.comments)) c
          where c->>'type' in ('quantity_done', 'quantity_share', 'quantity_team_total')
       )
     order by t.id
  loop
    perform public.recompute_task_quantity_shares(v_task_id);
  end loop;
end
$recompute$;

commit;
