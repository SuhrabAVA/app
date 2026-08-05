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
-- Сортировка по (proname, аргументы) — чтобы у перегруженных функций
-- (arrival_add, writeoff, recalculate_paint_reserved_qty) был устойчивый
-- порядок и следующий дамп давал читаемый diff.
--
-- ВАЖНО: новые функции создаются миграцией в supabase/migrations/, а не
-- правкой в дашборде. Этот дамп — только снимок того, что уже существует.

select
  '-- Снимок определений public-функций Supabase' || chr(10) ||
  '-- Снят: ' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' || chr(10) ||
  '-- Проект: ' || current_database() || chr(10) ||
  '-- Функций: ' || count(*) || chr(10) ||
  '-- Сгенерировано: scripts/dump_supabase_functions.sql' || chr(10) ||
  '--' || chr(10) ||
  '-- ЭТО СНИМОК ПРОДА, НЕ МИГРАЦИЯ.' || chr(10) ||
  '-- Не применять на чистой базе как есть: порядок и зависимости здесь не' || chr(10) ||
  '-- восстанавливаются, таблиц и типов файл не создаёт. Только для чтения и' || chr(10) ||
  '-- сравнения версий.' || chr(10) ||
  '--' || chr(10) ||
  '-- Новые функции создавать миграцией в supabase/migrations/.' || chr(10) ||
  chr(10) ||
  string_agg(
    '-- ' || repeat('=', 74) || chr(10) ||
    '-- ' || signature || chr(10) ||
    '-- ' || repeat('=', 74) || chr(10) ||
    definition || ';' || chr(10),
    chr(10) order by proname, signature
  ) as dump
from (
  select
    p.proname,
    p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' as signature,
    pg_get_functiondef(p.oid) as definition
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.prokind in ('f', 'p')
) s;
