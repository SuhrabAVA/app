-- Генератор снимка supabase/functions_dump.sql
--
-- Зачем: определения функций схемы public существуют только в проде — часть
-- создавалась через дашборд, а не миграцией. Снимок нужен, чтобы эта логика
-- была видна в репозитории и попадала в code review.
--
-- Как обновить снимок:
--   1. Выполнить этот запрос (SQL Editor в дашборде Supabase, psql или
--      MCP-инструмент execute_sql).
--   2. Единственное значение из результата целиком положить в
--      supabase/functions_dump.sql, заменив прежнее содержимое.
--
-- Строка md5 у каждой функции — md5(pg_get_functiondef). То же значение пишет
-- журнал изменений схемы (schema_change_log.definition_md5, шаг 13 от
-- 14.09.2026). Разошёлся md5 в снимке и в базе — функцию меняли мимо
-- репозитория: смотреть schema_change_log, кто и когда.
--
-- Сортировка по (proname, сигнатура) — чтобы у перегруженных функций был
-- устойчивый порядок и следующий дамп давал читаемый diff. Функции расширений
-- (pg_net и др.) в снимок не входят.
--
-- ВАЖНО: новые функции создаются миграцией в supabase/migrations/, а не
-- правкой в дашборде. Этот дамп — только снимок того, что уже существует.

select concat_ws(E'\n',
  '-- Снимок определений public-функций Supabase',
  '-- Снят: ' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC',
  '-- Функций: ' || count(*),
  '-- Снимает: MCP execute_sql (запрос в scripts/dump_supabase_functions.sql)',
  '--',
  '-- ЭТО СНИМОК ПРОДА, НЕ МИГРАЦИЯ. Не применять как есть.',
  '-- Зачем: видеть в git, какая версия функции была на проде, и ловить',
  '-- расхождение с миграциями (строка md5 у каждой функции совпадает с',
  '-- schema_change_log.definition_md5).',
  '',
  string_agg(
    '-- ' || p.oid::regprocedure::text || E'\n-- md5: ' || md5(pg_get_functiondef(p.oid)) || E'\n' || pg_get_functiondef(p.oid) || ';',
    E'\n\n' order by p.proname, p.oid::regprocedure::text)
) as dump
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.prokind in ('f', 'p')
  and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e');
