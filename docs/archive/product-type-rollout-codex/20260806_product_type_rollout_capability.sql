-- Product type rollout, M0: additive capability only.
--
-- Эта фаза безопасна для старого клиента: select(*) получает одно лишнее поле,
-- которое Dart-модели игнорируют; ни удаление, ни orders, ни конфиги, ни
-- триггеры здесь не меняются. Capability остаётся выключенной до успешного M1.

alter table public.warehouse_categories
  add column archived_at timestamptz;

comment on column public.warehouse_categories.archived_at is
  'NULL — активная категория. Непустое значение — категория архивирована. '
  'M0 только добавляет поле; архивирование начинается после включения capability.';

create table public.app_capabilities (
  code       text primary key,
  enabled    boolean not null,
  updated_at timestamptz not null default now()
);

comment on table public.app_capabilities is
  'Server-side feature capabilities. Клиент может только читать; переключение '
  'выполняется миграцией после полного создания и проверки схемы.';

insert into public.app_capabilities (code, enabled)
values ('product_type_form_blocks_v1', false);

revoke all on table public.app_capabilities
  from public, anon, authenticated;
grant select on table public.app_capabilities to authenticated;

alter table public.app_capabilities enable row level security;

create policy app_capabilities_authenticated_select
  on public.app_capabilities
  for select
  to authenticated
  using (true);
