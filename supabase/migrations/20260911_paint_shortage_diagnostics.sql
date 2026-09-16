-- Диагностика в тексте отказа «Недостаточно краски».
--
-- ЗАЧЕМ
-- Сообщение называет только две цифры — доступно и требуется, — и по ним
-- нельзя понять, какую карточку краски читала проверка, за какой заказ она
-- считала и из чего сложилось «доступно». Живой случай: «Доступно: 8300,
-- требуется: 38350» при остатке 85 000 и сумме чужих броней 35 000 — числа не
-- сходятся ни с одним состоянием базы, которое видно снаружи, и разбор занял
-- день переписки вместо минуты.
--
-- ЧТО ДОБАВЛЯЕТСЯ
-- В хвост сообщения: id карточки краски, id заказа-источника, прочитанный
-- остаток склада и сумма чужих броней — ровно те четыре величины, из которых
-- проверка делает вывод.
--
-- ПОЧЕМУ ТЕЛО ФУНКЦИИ БЕРЁТСЯ ИЗ БАЗЫ, А НЕ ИЗ РЕПОЗИТОРИЯ
-- Функцию уже переопределяли трижды, и копия не из последней версии молча
-- откатывает чужие правки — на этом проект обжигался в тот же день с
-- create_product_type_config_draft. Поэтому здесь берётся ДЕЙСТВУЮЩЕЕ
-- определение через pg_get_functiondef, в нём правится только текст raise, и
-- оно же исполняется обратно. Переписывать 21 КБ руками не нужно, и
-- расхождение с базой невозможно по построению.
--
-- ЕСЛИ ШАБЛОН НЕ СОВПАДЁТ — миграция падает с понятным текстом, а функция
-- остаётся нетронутой. Молча ничего не делать здесь нельзя: тогда следующий
-- отказ снова придёт без диагностики, и охота начнётся заново.

do $migration$
declare
  v_name text;
  v_def  text;
  v_new  text;
  v_patched int := 0;
begin
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

    if position('[diag ' in v_def) > 0 then
      raise notice 'Функция %: диагностика уже добавлена.', v_name;
      continue;
    end if;

    -- Оба вхождения (краски заказа и очередь) заменяются разом: текст raise в
    -- них одинаковый, различаются только переменные вокруг.
    v_new := regexp_replace(
      v_def,
      'Недостаточно краски: %\. Доступно: %, требуется: %''',
      'Недостаточно краски: %. Доступно: %, требуется: %.'
      || ' [diag paint=% order=% stock=% reserved=%]''',
      'g'
    );

    -- Аргументы дописываются к каждому такому raise. Якорь — закрывающая
    -- скобка round(...) перед точкой с запятой: она есть в обоих вариантах.
    v_new := regexp_replace(
      v_new,
      '(round\(v_amount::numeric, 2\));',
      '\1, coalesce(v_paint_id::text, ''?''),'
      || ' coalesce(v_source_order_id, ''?''),'
      || ' round(coalesce(v_stock_qty, 0)::numeric, 2),'
      || ' round(coalesce(v_reserved_other, 0)::numeric, 2);',
      'g'
    );
    v_new := regexp_replace(
      v_new,
      '(round\(rec\.qty::numeric, 2\));',
      '\1, coalesce(rec.paint_id::text, ''?''),'
      || ' coalesce(p_order_id, ''?''),'
      || ' round(coalesce(v_total_qty, 0)::numeric, 2),'
      || ' round(coalesce(v_reserved_other, 0)::numeric, 2);',
      'g'
    );

    if v_new = v_def then
      raise exception 'Функция %: шаблон сообщения не совпал, правка не '
        'применена. Функция осталась прежней.', v_name;
    end if;

    execute v_new;
    v_patched := v_patched + 1;
    raise notice 'Функция %: диагностика добавлена.', v_name;
  end loop;

  if v_patched = 0 then
    raise notice 'Ни одна функция не изменена.';
  end if;
end
$migration$;
