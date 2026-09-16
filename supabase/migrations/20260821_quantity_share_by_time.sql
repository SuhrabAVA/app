-- ============================================================================
-- Распределение количества между участниками совместного этапа (2026-08-21)
--
-- Что меняется в учёте
-- --------------------
-- На совместном этапе количество вводит один человек — основной исполнитель,
-- а работают несколько, приходя и уходя посреди смены. Сейчас введённое Q
-- засчитывается КАЖДОМУ участнику целиком (RPC complete_task_stage пишет
-- помощнику quantity_share с полным Q), а разницу в оплате делает процентная
-- скидка helper_percent. Помощник, пришедший на последний час пятичасового
-- этапа, получает столько же, сколько отработавший всю смену.
--
-- Дальше количество делится пропорционально фактически отработанному времени
-- (интервалы уже есть — это записи time_event в tasks.comments). Эта миграция
-- готовит для расчёта две настройки; сам расчёт приходит следующей миграцией.
--
-- 1. workplaces.split_quantity_by_time — делить ли количество по времени.
--    На станках, где бригада обслуживает ОДНУ машину, вклад по часам не
--    измеряется: тираж делает станок, а не сумма человеко-часов. Там всем
--    участникам по-прежнему пишется полное Q, а разницу делает коэффициент.
--    Такие рабочие места перечислены ниже и выключаются этой миграцией;
--    дальше признак меняется из справочника рабочих мест, без правки кода.
--
-- 2. workplace_coefficients.helper_coefficient — отдельная ставка помощника
--    вместо процентной скидки. Процент выражал «помощник получает 80% от
--    основного»; абсолютная ставка позволяет задать обе цены независимо, что
--    честнее: ответственность основного исполнителя выше, и это не всегда
--    ровный процент от его ставки.
--
-- helper_percent НЕ удаляется: по нему считаются уже закрытые месяцы, и
-- пересчитывать выплаченные ведомости мы не будем. Колонка помечена
-- устаревшей, новые записи её не заполняют.
--
-- Про типы: workplaces.id сопоставляем через ::text — в живой базе рядом с
-- uuid есть строковые id рабочих мест ('w_bobiner'), см. прецедент 42883
-- (uuid = text) и примечание в 20260710_workplace_priladka.sql.
-- ============================================================================

begin;

do $preflight$
begin
  if to_regclass('public.workplaces') is null then
    raise exception using
      message = 'public.workplaces is missing',
      hint = 'Restore the workplaces table before applying this migration.';
  end if;

  if to_regclass('public.workplace_coefficients') is null then
    raise exception using
      message = 'public.workplace_coefficients is missing',
      hint = 'Apply the analytics/salary migrations first.';
  end if;

  -- Бэкофилл ставки помощника читает helper_percent. Без колонки он молча
  -- дал бы всем ставку основного исполнителя, то есть тихо отменил бы
  -- действующую скидку.
  if not exists (
    select 1 from information_schema.columns
     where table_schema = 'public'
       and table_name = 'workplace_coefficients'
       and column_name = 'helper_percent'
  ) then
    raise exception using
      message = 'public.workplace_coefficients.helper_percent is missing',
      hint = 'Apply 20260816_workplace_helper_percent.sql first.';
  end if;
end
$preflight$;

-- ── 1. Делить ли количество по времени ──────────────────────────────────────

alter table public.workplaces
  add column if not exists split_quantity_by_time boolean not null default true;

comment on column public.workplaces.split_quantity_by_time is
  'Делить ли количество этапа между участниками пропорционально '
  'отработанному времени. false — бригада обслуживает одну машину, тираж '
  'делает станок: каждому участнику записывается полное количество, '
  'разницу в оплате делает коэффициент помощника.';

-- Рабочие места, где количество не делится. Список согласован с цехом.
do $machines$
declare
  v_ids text[] := array[
    '0571c01c-f086-47e4-81b2-5d8b2ab91218', -- Флексопечать
    'b92a89d1-8e95-4c6d-b990-e308486e4bf1', -- Бабинорезка
    'fdbf1735-a67c-47c9-a7e1-90546e1fe6ed', -- Автомат большой
    'cbcbe469-b924-4064-ae05-885ccd1b842a', -- Автомат маленький
    'e62fc013-4785-43f3-b3ee-a3ca51777199', -- Труба
    '92d96ee9-0519-40b9-bd17-9bec475496b6', -- Фри
    '8337f16e-c2d1-42dc-966d-6277ba3c1a50', -- Окно
    '19a67630-8374-4f9f-ae5b-f2f66828720b'  -- Листорезка
  ];
  v_updated int;
  v_missing text[];
begin
  update public.workplaces
     set split_quantity_by_time = false
   where id::text = any(v_ids)
     and split_quantity_by_time is distinct from false;

  get diagnostics v_updated = row_count;

  select array_agg(wanted)
    into v_missing
    from unnest(v_ids) as wanted
   where not exists (
     select 1 from public.workplaces w where w.id::text = wanted
   );

  raise notice 'split_quantity_by_time = false: обновлено % рабочих мест', v_updated;

  -- Не падаем: справочник мог разойтись между окружениями, а половина
  -- миграции хуже, чем видимое предупреждение. Но молчать нельзя — иначе
  -- станок останется с делением по времени, и бригада получит доли вместо
  -- полного тиража.
  if v_missing is not null then
    raise warning 'В справочнике не найдены рабочие места: %. '
                  'Проставьте признак вручную.', v_missing;
  end if;
end
$machines$;

-- ── 2. Отдельная ставка помощника ───────────────────────────────────────────

alter table public.workplace_coefficients
  add column if not exists helper_coefficient numeric null;

-- Бэкофилл из процента: при -20% и ставке 10 помощник получал 8 — столько же
-- он получит и после перехода. Суммы не прыгают, дальше ставки правятся
-- вручную. helper_percent = 0 (по умолчанию) даёт ставку основного, то есть
-- ровно прежнее поведение.
update public.workplace_coefficients
   set helper_coefficient = coefficient * (1 + helper_percent / 100.0)
 where helper_coefficient is null
   and coefficient is not null;

do $helper_rate$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'workplace_coefficients_helper_coefficient_nonneg'
  ) then
    alter table public.workplace_coefficients
      add constraint workplace_coefficients_helper_coefficient_nonneg
      check (helper_coefficient is null or helper_coefficient >= 0);
  end if;
end
$helper_rate$;

comment on column public.workplace_coefficients.helper_coefficient is
  'Ставка за единицу для помощника совместной работы, ₸. null = помощник '
  'оплачивается по ставке основного исполнителя (coefficient). '
  'Версионируется по месяцам вместе с coefficient.';

comment on column public.workplace_coefficients.helper_percent is
  'УСТАРЕЛО (2026-08-21): заменено на helper_coefficient — абсолютную ставку '
  'помощника. Колонка сохранена, потому что по ней посчитаны уже закрытые '
  'месяцы. Новые записи её не заполняют.';

commit;
