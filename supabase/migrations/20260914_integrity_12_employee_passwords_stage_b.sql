-- ============================================================================
-- Целостность данных, шаг 12: убрать открытые пароли сотрудников (стадия Б)
--
-- !!! НЕ ПРИМЕНЯТЬ, ПОКА ВСЕ УСТРОЙСТВА НЕ ОБНОВЛЕНЫ !!!
--
-- Старые версии приложения сравнивают пароль с employees.password у себя.
-- После этой миграции поле пустое, и такие устройства перестанут пускать
-- сотрудников. Версии с employee_password_service.dart проверяют пароль на
-- сервере (шаг 11) и работают дальше.
--
-- Проверка перед применением: на всех планшетах и ПК стоит сборка от
-- 14.09.2026 или новее.
--
-- Что делает миграция
-- -------------------
-- 1. Триггер после сохранения пароля записывает хеш и стирает открытый текст.
-- 2. Открытый текст стирается у всех сотрудников (хеши уже есть — шаг 11).
-- 3. employees_view больше не отдаёт колонку password.
--
-- Последствие для отдела кадров: пароль сотрудника больше нельзя посмотреть,
-- только задать новый. Пустое поле пароля при сохранении карточки пароль не
-- меняет.
-- ============================================================================

begin;

create or replace function public.employees_sync_password_hash()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
begin
  if coalesce(trim(new.password), '') = '' then
    return null;
  end if;

  insert into employee_password_hashes(employee_id, password_hash, updated_at)
  values (new.id, extensions.crypt(trim(new.password), extensions.gen_salt('bf', 8)), now())
  on conflict (employee_id) do update
    set password_hash = excluded.password_hash,
        updated_at = excluded.updated_at;

  -- Открытый текст в базе не остаётся. Повторный вызов триггера на этом
  -- update выходит сразу: пароль уже пустой.
  update employees set password = '' where id = new.id;
  return null;
end
$function$;

update public.employees set password = '' where coalesce(password, '') <> '';

drop view if exists public.employees_view;
create view public.employees_view
with (security_invoker = true)
as
select e.id,
       e.last_name,
       e.first_name,
       e.patronymic,
       e.iin,
       e.photo_url,
       e.is_fired,
       e.comments,
       e.login,
       e.created_at,
       e.updated_at,
       coalesce(array_agg(ep.position_id) filter (where ep.position_id is not null), '{}'::text[]) as position_ids
  from public.employees e
  left join public.employee_positions ep on ep.employee_id = e.id
 group by e.id;

grant select on public.employees_view to authenticated, service_role;

commit;
