-- Отрезок тиража, в котором никто не отработал ни секунды, засчитывается
-- АВТОРУ записи, а не текущим исполнителям задачи.
--
-- ЗАЧЕМ
-- Количество вводят и после остановки: сотрудник ушёл на срочный заказ, станок
-- встал на пересмену, а выработку смены записали часом позже. Производственных
-- интервалов в таком отрезке ноль, и `task_quantity_share_preview` делила его
-- поровну между `assignees`. Но `assignees` — это ТЕКУЩИЕ исполнители задачи, а
-- этап, прошедший через пересмены, меняет людей, не меняя `assignees`: на «Фри»
-- заказа «Варио принт Burger king» (задача 55abdc4d) 17 003 шт ушли Аблимитову,
-- которого в ту смену на станке не было, — их ввели Жылкыбай (17 000) и Вуколов
-- (три записи по 1 шт).
--
-- Автор записи — верный адресат: на пересмене количество вводит сдающий смену,
-- то есть за свою же работу. Прежнее правило остаётся запасным для записей без
-- автора (старый формат).
--
-- То же правило теперь в `stage_participant_output.dart`: плитка этапа и
-- сдельная должны давать один ответ на вопрос «чей это тираж».
--
-- Патч накладывается на РАЗВЁРНУТОЕ определение через pg_get_functiondef — тело
-- функции не переписывается руками, поэтому разойтись с продом оно не может.
-- Миграция идемпотентна: повторный прогон видит, что правка уже на месте.

do $migration$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid)
    into v_def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'task_quantity_share_preview';

  if v_def is null then
    raise exception 'task_quantity_share_preview не найдена — патчить нечего';
  end if;

  if position($q$as author$q$ in v_def) > 0 then
    raise notice 'Правка уже применена, пропускаем.';
    return;
  end if;

  -- 1. Отрезок несёт автора записи тиража.
  v_new := regexp_replace(
    v_def,
    $q$public\.task_quantity_value\(c->>'text'\) as qty$q$,
    $q$public.task_quantity_value(c->>'text') as qty,
               coalesce(trim(c->>'userId'), '') as author$q$
  );

  v_new := regexp_replace(
    v_new,
    $q$select m\.seg_end, m\.qty$q$,
    $q$select m.seg_end, m.qty, m.author$q$
  );

  -- 2. Пустой отрезок достаётся автору; assignees — только запасной вариант.
  v_new := regexp_replace(
    v_new,
    $q$-- T_total = 0: в сегменте никто не отработал ни секунды\. Делим поровну\s+-- между исполнителями задачи\.\s+select a\.uid, 0::numeric\s+from unnest\(v_assignees\) as a\(uid\)\s+where not exists \(select 1 from positive\)\s+and coalesce\(trim\(a\.uid\), ''\) <> ''$q$,
    $q$-- T_total = 0: в отрезке никто не отработал ни секунды — станок стоял на
      -- пересмене или «проблеме», а тираж ввели уже после остановки. Делить не
      -- на кого, но и отдавать assignees нельзя: это ТЕКУЩИЕ исполнители, а
      -- смену мог сдавать другой человек. Засчитываем автору записи.
      select v_seg.author, 0::numeric
       where not exists (select 1 from positive)
         and v_seg.author <> ''
      union all
      -- Автор записи неизвестен (старый формат) — прежнее правило: поровну
      -- между исполнителями задачи.
      select a.uid, 0::numeric
        from unnest(v_assignees) as a(uid)
       where not exists (select 1 from positive)
         and v_seg.author = ''
         and coalesce(trim(a.uid), '') <> ''$q$
  );

  -- Кусается: если хоть один образец не совпал, тело осталось прежним, и
  -- «применённая» миграция молча не сделала бы ничего.
  if position($q$as author$q$ in v_new) = 0
     or position($q$select m.seg_end, m.qty, m.author$q$ in v_new) = 0
     or position($q$select v_seg.author, 0::numeric$q$ in v_new) = 0 then
    raise exception
      'Тело task_quantity_share_preview изменилось: образцы патча не совпали, правку нужно перенести вручную.';
  end if;

  execute v_new;
end
$migration$;
