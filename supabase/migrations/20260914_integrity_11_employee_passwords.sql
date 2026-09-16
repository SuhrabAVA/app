-- ============================================================================
-- Целостность данных, шаг 11: пароль сотрудника проверяет сервер (2026-09-14)
-- Стадия А — ничего не ломает.
--
-- Что чинит
-- ---------
-- Пароли сотрудников лежат открытым текстом в employees.password и уезжают на
-- каждое устройство вместе со списком сотрудников (employees_view). Приложение
-- сравнивает введённое с этим полем у себя: вход, добавление сотрудника во
-- вкладку, добавление помощника. До шага 10 список с паролями мог прочитать
-- любой, у кого есть адрес проекта и публичный ключ; и сейчас его читает любое
-- устройство с приложением.
--
-- Что делает миграция
-- -------------------
-- 1. employee_password_hashes — bcrypt-хеши паролей. Таблица закрыта: RLS без
--    политик, прав у anon/authenticated нет. Читают её только функции ниже.
-- 2. Триггер на employees: новый или изменённый пароль сразу хешируется.
--    Пустой пароль хеш не трогает — так форма сотрудника без поля пароля не
--    сбрасывает его.
-- 3. employee_verify_password(сотрудник, пароль) — единственная проверка.
-- 4. Хеши для всех текущих сотрудников.
--
-- Открытый текст пока остаётся: старые версии приложения на планшетах
-- сравнивают пароль сами. Когда все устройства обновятся, стадия Б
-- (20260914_integrity_12_employee_passwords_stage_b.sql) уберёт его из базы и
-- из employees_view.
-- ============================================================================

begin;

create table if not exists public.employee_password_hashes (
  employee_id text primary key references public.employees(id) on delete cascade,
  password_hash text not null,
  updated_at timestamptz not null default now()
);

comment on table public.employee_password_hashes is
  'bcrypt-хеши паролей сотрудников. Клиентам недоступна: читают только '
  'employee_verify_password и триггер employees_sync_password_hash.';

alter table public.employee_password_hashes enable row level security;
revoke all on table public.employee_password_hashes from anon, authenticated, public;

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
  if tg_op = 'UPDATE'
     and new.password is not distinct from old.password
     and exists (select 1 from employee_password_hashes h where h.employee_id = new.id) then
    return null;
  end if;

  insert into employee_password_hashes(employee_id, password_hash, updated_at)
  values (new.id, extensions.crypt(trim(new.password), extensions.gen_salt('bf', 8)), now())
  on conflict (employee_id) do update
    set password_hash = excluded.password_hash,
        updated_at = excluded.updated_at;
  return null;
end
$function$;

drop trigger if exists employees_sync_password_hash on public.employees;
create trigger employees_sync_password_hash
  after insert or update of password on public.employees
  for each row execute function public.employees_sync_password_hash();

create or replace function public.employee_verify_password(p_employee_id text, p_password text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_hash text;
begin
  select h.password_hash into v_hash
    from employee_password_hashes h
    join employees e on e.id = h.employee_id
   where h.employee_id = p_employee_id
     and coalesce(e.is_fired, false) = false;
  if v_hash is null then
    return false;
  end if;
  return v_hash = extensions.crypt(trim(coalesce(p_password, '')), v_hash);
end
$function$;

comment on function public.employee_verify_password(text, text) is
  'Проверка пароля сотрудника. Уволенный сотрудник не проходит.';

revoke execute on function public.employee_verify_password(text, text) from public, anon;
grant execute on function public.employee_verify_password(text, text) to authenticated, service_role;
revoke execute on function public.employees_sync_password_hash() from public, anon, authenticated;

insert into public.employee_password_hashes(employee_id, password_hash)
select e.id, extensions.crypt(trim(e.password), extensions.gen_salt('bf', 8))
  from public.employees e
 where coalesce(trim(e.password), '') <> ''
on conflict (employee_id) do nothing;

commit;
