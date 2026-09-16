-- ============================================================================
-- Нельзя снять с этапа человека, у которого идёт интервал (2026-09-09)
--
-- Что чинит
-- ---------
-- 02.09 Жанна Ерлан нажала «Начать» на этапе «С 2х листов» через 15 секунд
-- после Гулмарал. Клиент собирал новый список исполнителей из своего снимка
-- задачи и перезаписывал колонку `assignees` целиком — чей PATCH долетал
-- последним, тот и оставался в списке. Жанна пропала из исполнителей, её
-- строка кнопок исчезла с экрана, а открытый производственный интервал остался
-- висеть и мотал счётчик этапа 16 часов подряд.
--
-- В приложении это уже исправлено: действия уходят в `task_apply_stage_events`
-- списком намерений («добавь исполнителя»), а не готовым массивом. Но RLS на
-- `public.tasks` выключен, и любой клиент с anon-ключом по-прежнему может
-- переписать колонку напрямую — старая сборка на планшете, ручной запрос,
-- скрипт. Триггер закрывает это на уровне базы.
--
-- Правило
-- -------
-- Из `assignees` нельзя убрать сотрудника, у которого в комментариях задачи
-- остался НЕЗАКРЫТЫЙ интервал (`time_event` без `endTime`). Человек, чей
-- интервал идёт, физически стоит у станка — снять его с этапа значит потерять
-- его время.
--
-- Почему это не ломает штатные сценарии
-- -------------------------------------
-- Все три места, где исполнителя снимают, закрывают интервал ПЕРЕД снятием, и
-- делают это в одном вызове RPC — то есть к моменту проверки интервал в
-- `new.comments` уже закрыт (проверено по StageEventPlans):
--   * пересмена  — closeInterval(helper) → removeAssignee(helper);
--   * удаление помощника — closeInterval(helper) → removeAssignee(helper);
--   * возобновление после пересмены — claim_stage, а интервалы прошлой смены
--     закрываются до него, отдельным вызовом (_relatedTasks включает саму
--     задачу).
--
-- Аварийный обход
-- ---------------
-- Обслуживающему скрипту, которому правда нужно снять исполнителя с открытым
-- интервалом, достаточно в своей транзакции выполнить:
--     set local app.allow_assignee_drop = 'on';
-- Это осознанное действие одной строкой, а не отключение триггера.
-- ============================================================================

begin;

create or replace function public.tasks_guard_active_assignees()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog, pg_temp
as $fn$
declare
  v_removed text;
  v_has_open boolean;
  v_comments jsonb;
begin
  -- Явное разрешение на разовую операцию обслуживания.
  if coalesce(current_setting('app.allow_assignee_drop', true), '') = 'on' then
    return new;
  end if;

  -- Никого не убрали — проверять нечего. Добавление исполнителей и любые
  -- другие правки строки проходят без единого лишнего чтения.
  if coalesce(new.assignees, '{}') @> coalesce(old.assignees, '{}') then
    return new;
  end if;

  v_comments := public.task_comments_to_array(coalesce(new.comments, '[]'::jsonb));

  for v_removed in
    select x
      from unnest(coalesce(old.assignees, '{}'::text[])) as x
     where not (x = any (coalesce(new.assignees, '{}'::text[])))
  loop
    select exists (
      select 1
        from jsonb_array_elements(v_comments) c
       where c->>'type' = 'time_event'
         and left(coalesce(c->>'text', ''), 1) = '{'
         and ((c->>'text')::jsonb ->> 'subjectUserId') = v_removed
         and ((c->>'text')::jsonb ->> 'endTime') is null
    ) into v_has_open;

    if v_has_open then
      raise exception
        'Нельзя снять исполнителя % с задачи %: у него не закрыт интервал. '
        'Сначала закройте интервал (closeInterval), затем снимайте исполнителя.',
        v_removed, new.id
        using errcode = 'check_violation';
    end if;
  end loop;

  return new;
end;
$fn$;

drop trigger if exists tasks_guard_active_assignees on public.tasks;
create trigger tasks_guard_active_assignees
  before update of assignees on public.tasks
  for each row
  when (old.assignees is distinct from new.assignees)
  execute function public.tasks_guard_active_assignees();

commit;
