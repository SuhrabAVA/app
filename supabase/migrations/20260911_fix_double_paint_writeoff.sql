-- Двойное списание краски на флексопечати.
--
-- ЧТО ПРОИСХОДИЛО
-- Списание одной краски уменьшало склад на ДВА расхода. Функции флексопечати
-- делают две вещи подряд:
--
--   insert into paints_writeoffs(...);                                  -- 1
--   update paints set quantity = greatest(quantity - v_amount, 0) ...;  -- 2
--
-- Но остаток уменьшает уже сама вставка в `paints_writeoffs` — на ней висит
-- триггер, и это ОСНОВНОЙ путь списания в системе: через него же списывает
-- склад из интерфейса кладовщика. Явный update во второй строке — повтор.
--
-- Проявлялось не всегда, а когда остатка переставало хватать на удвоенный
-- расход. Живой случай: склад 85 000, списание 38 350, и следующая проверка в
-- той же транзакции видит 85 000 − 38 350 × 2 = 8 300 и отказывает —
-- «Недостаточно краски: доступно 8300, требуется 38350» при полном складе.
-- Транзакция откатывается, в `paints_writeoffs` следов не остаётся, и снаружи
-- ситуация выглядит необъяснимой.
--
-- ЧТО ДЕЛАЕТСЯ
-- Из обеих функций убирается ЯВНЫЙ update остатка. Триггер продолжает делать
-- своё — путь списания остаётся ровно один.
--
-- МИГРАЦИЯ ПРОВЕРЯЕТ СВОЁ ПРЕДПОЛОЖЕНИЕ
-- Если триггера на `paints_writeoffs` нет, убирать update НЕЛЬЗЯ: тогда он и
-- есть единственный способ уменьшить остаток, и краска перестала бы списываться
-- вовсе. Поэтому миграция сначала убеждается, что триггер существует, и падает,
-- ничего не изменив, если его не окажется.
--
-- Тело функций берётся из базы (pg_get_functiondef) и туда же возвращается —
-- переписывать 21 КБ руками не нужно, откатить чужие правки невозможно.

do $migration$
declare
  v_name       text;
  v_def        text;
  v_new        text;
  v_triggers   int;
  v_patched    int := 0;
begin
  -- ── Проверка предположения ───────────────────────────────────────────────
  select count(*) into v_triggers
    from pg_trigger t
   where t.tgrelid = 'public.paints_writeoffs'::regclass
     and not t.tgisinternal;

  if v_triggers = 0 then
    raise exception
      'На paints_writeoffs нет триггеров: остаток уменьшает только явный '
      'update, и убирать его нельзя — краска перестанет списываться. '
      'Миграция ничего не изменила.';
  end if;

  raise notice 'Триггеров на paints_writeoffs: %. Убираю явный update.',
    v_triggers;

  -- ── Правка функций ───────────────────────────────────────────────────────
  foreach v_name in array array[
    'complete_flex_printing_stage_with_paint_queue',
    'complete_flex_printing_stage'
  ]
  loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_name;

    if v_def is null then
      raise notice 'Функция %: не найдена, пропускаю.', v_name;
      continue;
    end if;

    -- Явный update остатка. Оба варианта написания: по v_amount (очередь и
    -- краски заказа) и по rec.qty (старая функция).
    v_new := regexp_replace(
      v_def,
      'update paints set quantity = greatest\(quantity - v_amount, 0\)\s*'
      || 'where id = v_paint_id;',
      '-- остаток уменьшает триггер на paints_writeoffs (20260911)',
      'g'
    );
    v_new := regexp_replace(
      v_new,
      'update paints set quantity = greatest\(quantity - rec\.qty, 0\)\s*'
      || 'where id = rec\.paint_id;',
      '-- остаток уменьшает триггер на paints_writeoffs (20260911)',
      'g'
    );

    if v_new = v_def then
      raise notice 'Функция %: явного update не найдено, уже исправлена.',
        v_name;
      continue;
    end if;

    execute v_new;
    v_patched := v_patched + 1;
    raise notice 'Функция %: двойное списание убрано.', v_name;
  end loop;

  if v_patched = 0 then
    raise notice 'Ни одна функция не изменена.';
  end if;
end
$migration$;
