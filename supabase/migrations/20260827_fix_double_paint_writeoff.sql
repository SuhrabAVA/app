-- Двойное списание краски при завершении флексопечати.
--
-- На paints_writeoffs висит триггер trg_paints_writeoff_apply
-- (paints_apply_writeoff), который уже уменьшает paints.quantity на qty
-- вставленной строки. complete_flex_printing_stage_with_paint_queue после
-- вставки уменьшала остаток ещё раз, вручную — и расход уходил со склада
-- дважды. Обе ветки функции (немедленное списание и списание из очереди)
-- содержали одну и ту же лишнюю строку.
--
-- Подпись бага на данных: у 13 красок разница «приход − расход − остаток»
-- совпала с суммой флексо-списаний ровно, коэффициент 1.000. Там, где второе
-- вычитание упиралось в greatest(…, 0), часть перерасхода срезалась молча —
-- поэтому у «тест Оранжевый» коэффициент вышел меньше единицы, а 40 000 г
-- списания по заказу «ИП Данилов лосось» обнулили склад без следа в истории.
--
-- Правка хирургическая: тело берём из pg_get_functiondef и вырезаем только
-- строки ручного вычитания. Переписывать 400 строк plpgsql ради двух строк —
-- лишний риск на самом горячем пути производства, поэтому вместо переноса
-- текста здесь стоит проверка: если совпадений не ровно два, миграция падает,
-- а не правит наугад.

do $migration$
declare
  c_manual constant text :=
    'update paints set quantity = greatest(quantity - v_amount, 0) where id = v_paint_id;';
  c_replacement constant text :=
    'null; /* остаток уменьшает триггер trg_paints_writeoff_apply на paints_writeoffs */';
  v_def text;
  v_hits integer;
begin
  select pg_get_functiondef(p.oid)
    into v_def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'complete_flex_printing_stage_with_paint_queue';

  if v_def is null then
    raise exception
      'Функция complete_flex_printing_stage_with_paint_queue не найдена.';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, c_manual, '')))
            / length(c_manual);

  if v_hits <> 2 then
    raise exception
      'Ожидалось 2 ручных вычитания остатка краски, найдено %. Функция изменилась — сверьте её текст перед применением миграции.',
      v_hits;
  end if;

  execute replace(v_def, c_manual, c_replacement);
end
$migration$;

-- Ручных вычитаний в функции остаться не должно: остаток ведёт только триггер.
do $verify$
declare
  v_left integer;
begin
  select (length(d) - length(replace(d, 'update paints set quantity', '')))
         / length('update paints set quantity')
    into v_left
    from (
      select pg_get_functiondef(p.oid) as d
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname = 'complete_flex_printing_stage_with_paint_queue'
    ) s;

  if v_left <> 0 then
    raise exception
      'После миграции в функции осталось % ручных вычитаний остатка краски.',
      v_left;
  end if;
end
$verify$;
