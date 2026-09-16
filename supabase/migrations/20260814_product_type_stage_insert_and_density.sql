-- T4: плотность рангов и серверная вставка этапа.
--
-- ЗАЧЕМ ЭТО ВМЕСТЕ
-- Перенумерация закреплённой упаковки с ранга 999 в max + 1 сама по себе
-- небезопасна. Клиент выдавал новому этапу ранг max(незакреплённых) + 1 —
-- ровно тот, который перенумерация отдаёт упаковке. Совпадение рангов не
-- ломает план (сборщик отделяет закреплённый хвост), но в редакторе этапы
-- одного ранга — одна группа: новый этап нарисовался бы В СТРОКЕ упаковки как
-- её альтернатива и стал бы неперемещаемым, потому что группа с закреплённым
-- этапом исключена из перестановки.
--
-- Поэтому ранг перестаёт вычисляться на клиенте. Вставка этапа — это теперь
-- два оператора (выдать ранг новому этапу и сдвинуть закреплённый), и между
-- ними маршрут был бы с двумя этапами на одном ранге. Клиент такое атомарно
-- сделать не может, а обрыв оставил бы ту самую слипшуюся группу — то есть
-- состояние, из которого редактор не выводит.

-- 1. Плотность рангов.
--
-- Ранг 999 был заглушкой «всегда последний». После этой правки упаковка стоит
-- сразу за последним подвижным этапом, и её положение поддерживает функция
-- ниже. Порядок этапов не меняется: 999 и max + 1 одинаково последние.
-- Заказы в работе не затрагиваются — их планы уже разложены по
-- prod_plan_stages со своими номерами шагов.
update public.product_type_stages s
   set position = coalesce(
         (select max(s2.position) from public.product_type_stages s2
           where s2.config_id = s.config_id and not s2.is_pinned_last), 0) + 1
 where s.is_pinned_last;

-- 2. Вставка этапа с рангом, выданным сервером.
--
-- В конец, а не между: вставка «между» неявно сдвинула бы ранги существующих
-- этапов, то есть изменила маршрут там, куда техлид не смотрел. Для под-этапа
-- это заодно бесплатно соблюдает инвариант «после своего переключателя» —
-- переключатель заведомо стоит выше.
create or replace function public.insert_product_type_stage(
  p_config_id         uuid,
  p_stage_group_key   text,
  p_title             text,
  p_workplace_id      text,
  p_parent_variant_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_rank          integer;
  v_level         integer;
  v_parent_stage  uuid;
  v_parent_mode   text;
  v_parent_config uuid;
  v_stage         uuid;
begin
  if p_config_id is null or p_stage_group_key is null
     or p_title is null or p_workplace_id is null then
    raise exception
      'Не удалось создать этап: не хватает данных.'
      using errcode = '22023';
  end if;

  -- Блокировка версии до COMMIT: два одновременных добавления иначе получили
  -- бы один и тот же ранг и слиплись бы в одну группу.
  perform 1 from product_type_configs where id = p_config_id for update;

  if not found then
    raise exception
      'Не удалось создать этап: версия настроек не найдена. Обновите экран.'
      using errcode = 'P0002';
  end if;

  v_level := case when p_parent_variant_id is null then 0 else 1 end;

  if p_parent_variant_id is not null then
    select w.stage_id, s.selection_mode, s.config_id
      into v_parent_stage, v_parent_mode, v_parent_config
      from product_type_stage_workplaces w
      join product_type_stages s on s.id = w.stage_id
     where w.id = p_parent_variant_id;

    if v_parent_stage is null then
      raise exception
        'Не удалось создать под-этап: вариант не найден. Обновите экран.'
        using errcode = 'P0002';
    end if;

    -- Те же инварианты, что validate_product_type_config поймал бы при
    -- публикации, но в момент действия: техлид видит отказ там, где нажал.
    if v_parent_config <> p_config_id then
      raise exception
        'Не удалось создать под-этап: вариант принадлежит другой версии '
        'настроек. Обновите экран.'
        using errcode = '22023';
    end if;

    if v_parent_mode <> 'one_of' then
      raise exception
        'Не удалось создать под-этап: этап-владелец не переключаемый.'
        using errcode = '22023';
    end if;
  end if;

  select coalesce(max(position), 0) + 1 into v_rank
    from product_type_stages
   where config_id = p_config_id
     and not is_pinned_last;

  -- Закреплённый этап уходит на ранг выше нового. Это и есть та вторая
  -- половина операции, ради атомарности которой функция существует.
  update product_type_stages
     set position = v_rank + 1
   where config_id = p_config_id
     and is_pinned_last;

  insert into product_type_stages(
    config_id, parent_variant_id, level, stage_group_key, title,
    position, selection_mode)
  values (
    p_config_id, p_parent_variant_id, v_level, p_stage_group_key, p_title,
    v_rank, 'all')
  returning id into v_stage;

  -- Первое рабочее место сразу: этап без рабочих мест не проходит
  -- validate_product_type_config, и создавать заведомо невалидную строку,
  -- чтобы техлид её потом чинил, незачем.
  insert into product_type_stage_workplaces(
    stage_id, workplace_id, is_default, sort_order)
  values (v_stage, p_workplace_id, false, 1);

  return v_stage;
end;
$function$;

comment on function public.insert_product_type_stage(uuid, text, text, text, uuid) is
  'Создаёт этап маршрута с одним рабочим местом в конце последовательности. '
  'Ранг выдаёт сервер, закреплённый этап сдвигается на ранг выше — обе '
  'половины одной транзакцией, иначе маршрут остался бы с двумя этапами на '
  'одном ранге, то есть со слипшейся группой. Общий путь для этапа верхнего '
  'уровня, этапа-группы и под-этапа варианта.';

revoke execute on function
  public.insert_product_type_stage(uuid, text, text, text, uuid) from public;
grant execute on function
  public.insert_product_type_stage(uuid, text, text, text, uuid) to authenticated;
