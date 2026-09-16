-- Отдельная ставка помощника в совместной работе (2026-08-16).
--
-- На рабочих местах с режимом «Одиночная или совместная работа» этап ведёт
-- основной исполнитель (тот, кто его начал), а остальные — помощники. После
-- завершения этапа сделанное количество засчитывается КАЖДОМУ участнику
-- целиком: сделали 6000 штук — у всех по 6000. Но ответственности и работы у
-- основного больше, поэтому помощник должен получать за то же количество
-- меньше.
--
-- helper_percent — поправка к коэффициенту рабочего места в процентах,
-- применяется только к помощникам: -20 значит «помощник получает 80% от
-- основного коэффициента». 0 (по умолчанию) — все получают одинаково, то
-- есть поведение до этой миграции. Диапазон -100…0: помощник не может
-- получать больше основного, а -100 обнуляет его сдельную.
--
-- Колонка живёт в workplace_coefficients, а не в workplaces: ставка
-- версионируется по месяцам вместе с самим коэффициентом, и прошлые месяцы
-- пересчитываться не должны.

alter table public.workplace_coefficients
  add column if not exists helper_percent numeric not null default 0;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'workplace_coefficients_helper_percent_range'
  ) then
    alter table public.workplace_coefficients
      add constraint workplace_coefficients_helper_percent_range
      check (helper_percent >= -100 and helper_percent <= 0);
  end if;
end
$$;

comment on column public.workplace_coefficients.helper_percent is
  'Поправка к коэффициенту для помощников совместной работы, %. '
  '-20 = помощник получает 80% от основного коэффициента. 0 = поровну.';
