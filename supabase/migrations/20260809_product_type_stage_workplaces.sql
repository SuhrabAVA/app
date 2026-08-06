-- Панель рабочих мест этапа: смена режима и назначение варианта по умолчанию.
--
-- ОБЩАЯ ПРИЧИНА
-- Обе операции состоят больше чем из одного оператора, а одна из них ещё и
-- разрушительна. Обрыв между запросами оставил бы переключаемый этап без
-- варианта по умолчанию либо удалённые под-этапы при неизменённом режиме —
-- то же, чего мы не допускаем в publish_product_type_config,
-- create_product_type_config_draft и set_product_type_stage_positions.
--
-- ЧЕГО ЗДЕСЬ НЕТ И ПОЧЕМУ
-- Удаления рабочего места. Это один оператор DELETE, он атомарен сам по себе,
-- и каскад на под-этапы — его часть. Опасна там была не потеря атомарности, а
-- ТИШИНА: parent_variant_id ссылается на product_type_stage_workplaces с
-- ON DELETE CASCADE, поэтому удаление варианта «Труба» бесшумно уносит
-- «Сборку дно+картон» и «Склейку дна». Лечится диалогом с перечислением до
-- удаления, а не серверной функцией.
--
-- Добавления рабочего места тоже нет: один INSERT.

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. Смена режима этапа
-- ═══════════════════════════════════════════════════════════════════════════
--
-- all → one_of
--   Рабочие места становятся вариантами. variant_title заполняется именем
--   рабочего места из справочника там, где пусто — ровно так названы варианты
--   в сиде («Фри», «Окно», «Труба» это имена РМ). is_default достаётся первому
--   по sort_order: детерминированно и совпадает с сидом, где Фри и Автомат
--   большой имеют sort_order = 1 и они же по умолчанию.
--   Требуется не меньше двух рабочих мест — переключать иначе нечем.
--
-- one_of → all
--   Варианты перестают быть альтернативами, значит под-этапы, привязанные к
--   ним, теряют смысл: условие «выбран вариант X» больше не существует.
--   Они УДАЛЯЮТСЯ, и функция возвращает их число, чтобы UI отчитался фактом,
--   а не обещанием. Перечисление того, что пропадёт, показывается техлиду ДО
--   вызова — диалог строится на клиенте из уже загруженного маршрута.
--
--   Важно: каскад здесь НЕ срабатывает сам. Смена режима — это UPDATE
--   selection_mode, строки рабочих мест не удаляются, и под-этапы остались бы
--   жить привязанными к более не переключаемому этапу. Конфиг стал бы
--   невалидным (sub_stage_parent_not_switchable), и техлид узнал бы об этом
--   при публикации, далеко от места, где переключил тумблер. Поэтому удаляем
--   явно.
--
--   variant_title и is_default сохраняются: для режима all они не читаются, а
--   обратная конверсия восстановит подписи без потерь.
--
-- ЧТО МЕНЯЕТСЯ ДЛЯ ОПЕРАТОРА
-- Имя этапа в очереди для one_of берётся из variant_title выбранного
-- варианта, для all — из product_type_stages.title. Конверсия в любую сторону
-- меняет то, что оператор видит в очереди; предупреждение об этом — часть
-- диалога в редакторе.

create or replace function public.set_product_type_stage_selection_mode(
  p_stage_id uuid,
  p_mode     text
)
returns integer
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_current   text;
  v_title     text;
  v_workplace integer;
  v_deleted   integer := 0;
begin
  if p_stage_id is null then
    raise exception
      'Не удалось сменить режим этапа: не указан этап.'
      using errcode = '22023';
  end if;

  if p_mode is null or p_mode not in ('all', 'one_of') then
    raise exception
      'Не удалось сменить режим этапа: недопустимый режим «%».', p_mode
      using errcode = '22023';
  end if;

  -- Фиксируем этап и его рабочие места до COMMIT: параллельная правка не
  -- добавит и не уберёт вариант между проверкой и записью.
  select selection_mode, title into v_current, v_title
    from product_type_stages
   where id = p_stage_id
   for update;

  if not found then
    raise exception
      'Не удалось сменить режим этапа: этап не найден. Обновите экран.'
      using errcode = 'P0002';
  end if;

  perform 1 from product_type_stage_workplaces
   where stage_id = p_stage_id
   for update;

  if v_current = p_mode then
    return 0;
  end if;

  if p_mode = 'one_of' then
    select count(*) into v_workplace
      from product_type_stage_workplaces
     where stage_id = p_stage_id;

    if v_workplace < 2 then
      raise exception
        'Не удалось сделать этап «%» переключаемым: нужно не меньше двух '
        'рабочих мест, сейчас %.', v_title, v_workplace
        using errcode = '22023';
    end if;

    -- Подпись варианта по умолчанию — имя рабочего места из справочника.
    update product_type_stage_workplaces w
       set variant_title = coalesce(
             nullif(btrim(coalesce(w.variant_title, '')), ''),
             (select name from workplaces where id = w.workplace_id))
     where w.stage_id = p_stage_id;

    -- Ровно один вариант по умолчанию: первый по sort_order. Второй ключ
    -- сортировки нужен, чтобы выбор был детерминированным при равных
    -- sort_order.
    update product_type_stage_workplaces
       set is_default = false
     where stage_id = p_stage_id
       and is_default;

    update product_type_stage_workplaces
       set is_default = true
     where id = (
       select id from product_type_stage_workplaces
        where stage_id = p_stage_id
        order by sort_order, workplace_id
        limit 1);

  else
    -- Под-этапы вариантов этого этапа теряют смысл вместе с вариантами.
    -- Их собственные рабочие места и условия уходят каскадом по stage_id.
    with removed as (
      delete from product_type_stages s
       where s.parent_variant_id in (
         select id from product_type_stage_workplaces
          where stage_id = p_stage_id)
      returning 1
    )
    select count(*) into v_deleted from removed;
  end if;

  update product_type_stages
     set selection_mode = p_mode
   where id = p_stage_id;

  return v_deleted;
end;
$function$;

comment on function public.set_product_type_stage_selection_mode(uuid, text) is
  'Меняет режим этапа одной транзакцией. all → one_of: требует не меньше двух '
  'рабочих мест, заполняет подписи вариантов именами РМ и назначает первый по '
  'sort_order вариантом по умолчанию. one_of → all: удаляет под-этапы '
  'вариантов и возвращает их число. Повторный вызов с тем же режимом ничего '
  'не делает и возвращает 0.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. Назначение варианта по умолчанию
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ПОЧЕМУ ЭТО НЕ ОДИН UPDATE
-- Единственность варианта по умолчанию держит ЧАСТИЧНЫЙ уникальный индекс
-- product_type_stage_workplaces_default_uq on (stage_id) where is_default.
-- Частичный индекс нельзя объявить DEFERRABLE (откладывать умеют только
-- уникальные КОНСТРЕЙНТЫ, а они не умеют быть частичными). Поэтому
-- «снять у старого и поставить новому» одним оператором
--   update ... set is_default = (id = p_variant_id) where stage_id = ...
-- ненадёжно: если новая строка обновится раньше старой, в этот момент
-- окажется два варианта по умолчанию и индекс отвергнет операцию. Порядок
-- обработки строк внутри UPDATE не определён, то есть падать это будет через
-- раз — худший вид дефекта.
--
-- Отсюда два оператора в одной транзакции: сначала снять, потом назначить.
--
-- ЗАЧЕМ ЭТО ВООБЩЕ НУЖНО В ЭТОМ СРЕЗЕ
-- Удаление варианта по умолчанию оставило бы переключаемый этап без него, и
-- техлид узнал бы об этом при публикации. Поэтому в панели такое удаление
-- запрещено с подсказкой «сначала назначьте вариантом по умолчанию другой» —
-- а значит нужен способ его назначить.

create or replace function public.set_product_type_stage_default_variant(
  p_variant_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_stage_id uuid;
  v_mode     text;
begin
  if p_variant_id is null then
    raise exception
      'Не удалось назначить вариант по умолчанию: не указан вариант.'
      using errcode = '22023';
  end if;

  select w.stage_id, s.selection_mode into v_stage_id, v_mode
    from product_type_stage_workplaces w
    join product_type_stages s on s.id = w.stage_id
   where w.id = p_variant_id;

  if not found then
    raise exception
      'Не удалось назначить вариант по умолчанию: вариант не найден. '
      'Обновите экран.'
      using errcode = 'P0002';
  end if;

  if v_mode <> 'one_of' then
    raise exception
      'Не удалось назначить вариант по умолчанию: этап не переключаемый.'
      using errcode = '22023';
  end if;

  perform 1 from product_type_stage_workplaces
   where stage_id = v_stage_id
   for update;

  update product_type_stage_workplaces
     set is_default = false
   where stage_id = v_stage_id
     and is_default
     and id <> p_variant_id;

  update product_type_stage_workplaces
     set is_default = true
   where id = p_variant_id
     and not is_default;
end;
$function$;

comment on function public.set_product_type_stage_default_variant(uuid) is
  'Назначает вариант переключаемого этапа вариантом по умолчанию, снимая '
  'признак с прежнего. Два оператора в одной транзакции: частичный уникальный '
  'индекс нельзя отложить, а одиночный UPDATE по всем строкам этапа падал бы '
  'через раз в зависимости от порядка обработки строк.';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. Права
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Политик и грантов на таблицы миграция не меняет: обе функции работают с уже
-- существующими product_type_stages и product_type_stage_workplaces, права на
-- которые выданы в 20260807_product_type_stages.sql.

revoke execute on function
  public.set_product_type_stage_selection_mode(uuid, text) from public;
grant execute on function
  public.set_product_type_stage_selection_mode(uuid, text) to authenticated;

revoke execute on function
  public.set_product_type_stage_default_variant(uuid) from public;
grant execute on function
  public.set_product_type_stage_default_variant(uuid) to authenticated;
