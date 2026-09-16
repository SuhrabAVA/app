-- Редактирование условия этапа маршрута.
--
-- ЗАЧЕМ СЕРВЕРНАЯ ФУНКЦИЯ
-- Условие у этапа одно, поэтому его замена — это DELETE всех условий этапа
-- плюс INSERT нового. Два оператора, и между ними этап на мгновение
-- «всегда». Черновик никем не читается, так что порчи данных не будет, но
-- обрыв между шагами оставил бы этап без условия — то есть добавляемым
-- всегда, — и техлид узнал бы об этом не сразу. Тот же класс, что и в
-- остальных операциях редактора.
--
-- ЧТО ФУНКЦИЯ ПРОВЕРЯЕТ
-- Те же инварианты, что validate_product_type_config ловит при публикации
-- (bad_handle_type_param, unexpected_param), но в момент действия: техлид
-- видит отказ там, где нажал, а не через десять шагов.
--
-- ОДНО УСЛОВИЕ НА ЭТАП
-- После перехода на подочереди каждое из 36 правил сводится максимум к одному
-- предикату: отрицание, которое было нужно правилу «Вставка картона при
-- картоне И НЕ Труба», выражается принадлежностью под-этапа варианту. Поэтому
-- функция заменяет условие целиком, а не добавляет ещё одно. Колонки negate и
-- возможность нескольких условий остаются в схеме заделом и через эту функцию
-- недоступны.
--
-- p_predicate = NULL означает «всегда»: строки условий просто удаляются.

create or replace function public.set_product_type_stage_condition(
  p_stage_id  uuid,
  p_predicate text,
  p_param     text default null
)
returns void
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_title      text;
  v_param_kind text;
begin
  if p_stage_id is null then
    raise exception
      'Не удалось сохранить условие: не указан этап.'
      using errcode = '22023';
  end if;

  select title into v_title
    from product_type_stages
   where id = p_stage_id
   for update;

  if not found then
    raise exception
      'Не удалось сохранить условие: этап не найден. Обновите экран.'
      using errcode = 'P0002';
  end if;

  -- «Всегда» — это отсутствие строк условий, а не отдельный предикат. Тот же
  -- принцип, что у product_type_form_blocks: таблицы хранят отклонения.
  if p_predicate is null then
    delete from product_type_stage_conditions where stage_id = p_stage_id;
    return;
  end if;

  select param_kind into v_param_kind
    from order_predicates
   where code = p_predicate;

  if not found then
    raise exception
      'Не удалось сохранить условие: неизвестное условие «%».', p_predicate
      using errcode = '23503';
  end if;

  if v_param_kind is null and p_param is not null then
    raise exception
      'Не удалось сохранить условие этапа «%»: условие «%» не принимает '
      'значения.', v_title, p_predicate
      using errcode = '22023';
  end if;

  if v_param_kind = 'handle_type'
     and coalesce(p_param, '') not in ('flat', 'twisted', 'dieCut') then
    raise exception
      'Не удалось сохранить условие этапа «%»: недопустимый тип ручки «%».',
      v_title, coalesce(p_param, '—')
      using errcode = '22023';
  end if;

  delete from product_type_stage_conditions where stage_id = p_stage_id;

  insert into product_type_stage_conditions(stage_id, predicate, param_text)
  values (p_stage_id, p_predicate, p_param);
end;
$function$;

comment on function public.set_product_type_stage_condition(uuid, text, text) is
  'Заменяет условие этапа целиком одной транзакцией. NULL в p_predicate '
  'означает «всегда» — строки условий удаляются. Проверяет предикат по '
  'справочнику и соответствие параметра его param_kind, то есть ловит в '
  'момент действия то, что validate_product_type_config поймал бы при '
  'публикации.';

revoke execute on function
  public.set_product_type_stage_condition(uuid, text, text) from public;
grant execute on function
  public.set_product_type_stage_condition(uuid, text, text) to authenticated;
