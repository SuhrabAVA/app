-- Атомарная публикация версии настроек типа продукта.
--
-- ЗАЧЕМ
-- Клиент публиковал двумя отдельными update: сначала переводил текущую
-- published в archived, потом draft в published. Порядок вынужденный —
-- частичный уникальный индекс product_type_configs_published_uq допускает
-- только одну published на тип продукта, поэтому «сначала опубликовать»
-- невозможно. Транзакции из клиента нет, и обрыв между шагами оставлял тип
-- продукта ВООБЩЕ без опубликованной версии: настройки молча переставали
-- действовать, форма показывала все блоки, а причину пришлось бы искать
-- через месяц. Тот же класс дефекта, что и в replace_plan_stages.
--
-- ЗАЩИТА ОТ ГОНКИ
-- SELECT ... FOR UPDATE по целевой строке фиксирует её статус до COMMIT:
-- параллельная публикация того же черновика подождёт и увидит уже
-- изменённый статус, то есть упадёт на проверке «версия не черновик».
-- Случай посложнее — два РАЗНЫХ черновика одного типа продукта публикуются
-- одновременно. Второй заблокируется на update строки published, а после
-- коммита первого не найдёт её по status='published' и архивировать будет
-- нечего. Дальше он упёрся бы в уникальный индекс с кодом 23505 и невнятным
-- текстом, поэтому перед финальным update стоит явная проверка, которая
-- превращает это в понятное сообщение. Черновик проигравшего при этом цел.
--
-- SECURITY DEFINER
-- По той же причине, что и в replace_plan_stages: инвариант «ровно одна
-- опубликованная версия на тип продукта» должен держаться независимо от того,
-- какие политики появятся у таблицы позже. Обязательные спутники — явный
-- search_path и снятие права выполнения с public.

create or replace function public.publish_product_type_config(
  p_config_id uuid
)
returns uuid
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_product_type_id uuid;
  v_status          text;
  v_version         integer;
begin
  ---------------------------------------------------------------------------
  -- 1. Валидация входа. Тексты читает техлид в снекбаре, не разработчик.
  ---------------------------------------------------------------------------
  if p_config_id is null then
    raise exception
      'Не удалось опубликовать настройки: не указана версия.'
      using errcode = '22023';
  end if;

  select product_type_id, status, version
    into v_product_type_id, v_status, v_version
    from product_type_configs
   where id = p_config_id
   for update;

  -- P0002 (no_data_found), а не 23503: тот означает foreign_key_violation и
  -- здесь семантически неверен. В этом же релизе хаб категорий разбирает 23503
  -- как «на категорию ссылаются заказы», и любой общий обработчик, ветвящийся
  -- по коду, а не по тексту, показал бы неверное сообщение.
  if not found then
    raise exception
      'Не удалось опубликовать настройки: версия не найдена. Обновите экран.'
      using errcode = 'P0002';
  end if;

  if v_status <> 'draft' then
    raise exception
      'Не удалось опубликовать настройки: версия % уже имеет статус «%», '
      'публиковать можно только черновик. Обновите экран.',
      v_version, v_status
      using errcode = '22023';
  end if;

  ---------------------------------------------------------------------------
  -- 2. Прежняя опубликованная версия уходит в архив.
  --    Версии не удаляются физически: на них ссылается orders.stage_config_id.
  ---------------------------------------------------------------------------
  update product_type_configs
     set status = 'archived'
   where product_type_id = v_product_type_id
     and status = 'published';

  ---------------------------------------------------------------------------
  -- 3. Страховка от параллельной публикации другого черновика того же типа.
  --    Без неё здесь был бы 23505 по уникальному индексу.
  ---------------------------------------------------------------------------
  if exists (
    select 1
      from product_type_configs
     where product_type_id = v_product_type_id
       and status = 'published'
       and id <> p_config_id
  ) then
    raise exception
      'Не удалось опубликовать настройки: параллельно опубликована другая '
      'версия. Обновите экран и повторите.'
      using errcode = '40001';
  end if;

  ---------------------------------------------------------------------------
  -- 4. Черновик становится действующей версией.
  ---------------------------------------------------------------------------
  update product_type_configs
     set status       = 'published',
         published_at = now()
   where id = p_config_id;

  return p_config_id;
end;
$function$;

comment on function public.publish_product_type_config(uuid) is
  'Атомарно публикует черновик настроек типа продукта: прежнюю опубликованную '
  'версию переводит в archived, черновик — в published с published_at. '
  'Возвращает id опубликованной версии. Публиковать можно только строку со '
  'status = draft.';

revoke execute on function public.publish_product_type_config(uuid) from public;
grant  execute on function public.publish_product_type_config(uuid) to authenticated;
