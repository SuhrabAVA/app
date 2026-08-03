-- Фаза 1 (actual_qty после упаковки): точный момент завершения задачи.
--
-- Клиент уже пишет completed_at (millis) при завершении этапа
-- (_syncStageGroupStatusToSharedSources в task_provider.dart) и молча
-- отбрасывает поле, пока колонки нет (fallback на 42703/PGRST204).
-- Пересчёт actual_qty использует completed_at как приоритетный источник
-- момента завершения упаковки; без колонки работает fallback по меткам
-- завершающих комментариев (user_done / quantity_*).
--
-- Применение: Supabase Studio → SQL Editor → выполнить целиком.

alter table public.tasks
  add column if not exists completed_at bigint;

comment on column public.tasks.completed_at is
  'Момент завершения этапа, millis since epoch (пишет клиент при status=completed)';
