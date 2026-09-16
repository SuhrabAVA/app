-- ============================================================================
-- Целостность данных, шаг 13: журнал изменений схемы базы (2026-09-14)
--
-- Что чинит
-- ---------
-- Большинство миграций катались через SQL-редактор и не оставляли следа: в
-- журнале миграций 19 записей при 25 файлах только за сентябрь. 08.09
-- миграция пересоздала advance_order_after_task_completion из старого снимка
-- и молча выключила списание бумаги на этапе — заметили через неделю, по
-- жалобе, восстанавливая ход событий по косвенным признакам.
--
-- Что делает миграция
-- -------------------
-- schema_change_log — каждое изменение схемы (CREATE/ALTER/DROP функции,
-- таблицы, триггера, представления…): когда, кем (роль и приложение —
-- SQL-редактор, миграция, MCP), какой объект, текст команды и md5
-- определения функции. Запись делают event-триггеры; их функция глотает
-- собственные ошибки — журнал никогда не блокирует саму миграцию.
--
-- data_health_report получает проверку «функции, изменённые за 7 дней»:
-- неожиданное изменение видно сразу, а не через неделю.
-- ============================================================================

begin;

create table if not exists public.schema_change_log (
  id bigserial primary key,
  changed_at timestamptz not null default now(),
  event text not null,
  command_tag text not null,
  object_type text,
  object_identity text,
  definition_md5 text,
  statement text,
  db_user text not null default current_user,
  application_name text default current_setting('application_name', true),
  txid bigint not null default txid_current()
);

create index if not exists schema_change_log_changed_at_idx on public.schema_change_log(changed_at desc);
create index if not exists schema_change_log_object_idx on public.schema_change_log(object_identity);

comment on table public.schema_change_log is
  'Журнал изменений схемы (event-триггеры log_schema_change / log_schema_drop). '
  'application_name: mgmt-api — MCP и миграции через API, остальное — SQL-редактор и клиенты.';

alter table public.schema_change_log enable row level security;
revoke all on table public.schema_change_log from anon, authenticated, public;

create or replace function public.log_schema_change()
returns event_trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    begin
      if r.schema_name is null or r.schema_name not in ('public', 'production') then
        continue;
      end if;
      if r.object_identity like 'public.schema_change_log%' then
        continue;
      end if;
      insert into public.schema_change_log(event, command_tag, object_type, object_identity, definition_md5, statement)
      values (
        'ddl_command_end',
        r.command_tag,
        r.object_type,
        r.object_identity,
        case when r.object_type in ('function', 'procedure')
             then md5(pg_get_functiondef(r.objid)) end,
        left(current_query(), 20000)
      );
    exception when others then
      -- Журнал не должен ломать миграцию.
      null;
    end;
  end loop;
exception when others then
  null;
end
$function$;

create or replace function public.log_schema_drop()
returns event_trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r record;
begin
  for r in select * from pg_event_trigger_dropped_objects() loop
    begin
      if r.schema_name is null or r.schema_name not in ('public', 'production') then
        continue;
      end if;
      if not r.original then
        continue;
      end if;
      insert into public.schema_change_log(event, command_tag, object_type, object_identity, statement)
      values ('sql_drop', tg_tag, r.object_type, r.object_identity, left(current_query(), 20000));
    exception when others then
      null;
    end;
  end loop;
exception when others then
  null;
end
$function$;

revoke execute on function public.log_schema_change() from public, anon, authenticated;
revoke execute on function public.log_schema_drop() from public, anon, authenticated;

drop event trigger if exists log_schema_change;
create event trigger log_schema_change on ddl_command_end
  execute function public.log_schema_change();

drop event trigger if exists log_schema_drop;
create event trigger log_schema_drop on sql_drop
  execute function public.log_schema_drop();

-- Проверка в отчёте о здоровье данных.
do $patch$
declare
  v_sig constant regprocedure := 'public.data_health_report()'::regprocedure;
  v_def text := pg_get_functiondef(v_sig);
  v_anchor constant text := 'union all\s+select ''orphan_paint_rows''';
  v_count int;
begin
  if position('functions_changed_recently' in v_def) > 0 then
    raise notice 'data_health_report уже проверяет изменения функций — пропуск';
    return;
  end if;
  v_count := regexp_count(v_def, v_anchor);
  if v_count <> 1 then
    raise exception 'Шаблон orphan_paint_rows найден % раз(а) вместо 1', v_count;
  end if;

  v_def := regexp_replace(v_def, v_anchor,
    'union all' || chr(10)
    || '  select ''functions_changed_recently'', ''info'', ''Функции базы, изменённые за 7 дней'','
    || ' (select count(distinct object_identity) from schema_change_log'
    || '   where object_type in (''function'', ''procedure'') and changed_at > now() - interval ''7 days''),' || chr(10)
    || '         ''Сверьте со списком миграций: изменение не из миграции — повод разобраться, кто и зачем.'',' || chr(10)
    || '         (select jsonb_agg(x) from (select jsonb_build_object(''функция'', object_identity, ''когда'', max(changed_at),'
    || ' ''откуда'', string_agg(distinct coalesce(application_name, ''?''), '', ''), ''раз'', count(*)) x'
    || '   from schema_change_log where object_type in (''function'', ''procedure'') and changed_at > now() - interval ''7 days'''
    || '   group by object_identity order by max(changed_at) desc limit 10) s)' || chr(10)
    || '  union all' || chr(10)
    || '  select ''orphan_paint_rows''');
  execute v_def;
end
$patch$;

commit;
