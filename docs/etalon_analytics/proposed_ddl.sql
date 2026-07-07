-- ============================================================================
-- Фаза A (аудит соответствия эталону): предлагаемый DDL.
-- НЕ ПРИМЕНЯТЬ без утверждения. Дата аудита: 2026-07-06.
--
-- ГЛАВНЫЙ ВЫВОД АУДИТА: почти весь «новый» DDL уже существует в Supabase.
-- Проверено read-only запросами через PostgREST (anon key):
--
--   1. public.salary_settings — СУЩЕСТВУЕТ, есть данные
--      (effective_month, night_percent, meal_amount, social_default,
--       created_at, updated_at, updated_by).
--      Покрывает настройки эталона: nightPercent (getNightPercent)
--      и mealPortion (getMealPortion).
--
--   2. public.employee_month_salary_adjustments — СУЩЕСТВУЕТ (пустая),
--      все колонки подтверждены select'ом:
--      (id, employee_id, month, compensation, social, advance, cashless,
--       discipline, defect, updated_at, updated_by).
--      Покрывает редактируемые поля эталона (renderInlineMoneyInput /
--      renderSalaryEditor): Компенсация, Соцотчисления, Аванс, ЗП без нал,
--      Дисциплина, Браки.
--
--   3. public.employees.pay_type — СУЩЕСТВУЕТ (сейчас null у сотрудников).
--      Покрывает чип «Сдельно / оклад» (payTypeLabel).
--
-- Flutter-репозитории уже настроены на эти таблицы
-- (SalarySettingsRepository, SalaryAdjustmentsRepository), сервис уже
-- загружает и сохраняет эти данные (AnalyticsService.saveSalarySettings /
-- saveSalaryAdjustments). Новые таблицы для зарплатного блока НЕ НУЖНЫ.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- ЕДИНСТВЕННЫЙ недостающий элемент данных: оклад сотрудника за смену.
--
-- В эталоне (app.js): employee.baseDaySalary участвует в
--   baseShiftPay  = shifts * baseDaySalary          (строка ~766)
--   grossSalary   = baseShiftPay + productionPay + nightShiftPay
--   payTypeLabel  = «Оклад: <baseShiftPay>» для окладников (строка ~1232)
--
-- В Supabase колонки нет (проверено: employees.base_day_salary /
-- base_salary / day_salary / salary — 42703 column does not exist).
-- Без неё «Сдельно / оклад» для окладников не имеет источника суммы,
-- а «Итог ЗП» окладника не включает окладную часть.
-- ----------------------------------------------------------------------------

alter table public.employees
  add column if not exists base_day_salary numeric not null default 0;

comment on column public.employees.base_day_salary is
  'Оклад за одну смену (₸). Используется аналитикой: окладная часть ЗП = смены × base_day_salary. 0 = чисто сдельная оплата.';

-- RLS: колонка добавляется в существующую таблицу employees — действуют
-- текущие политики таблицы, отдельных политик не требуется.
