-- Таблица сообщений чата и bucket для вложений.

create table if not exists public.chat_messages (
  id text primary key,
  room_id text not null,
  sender_id text,
  sender_name text,
  kind text not null default 'text',
  body text,
  file_url text,
  file_mime text,
  duration_ms int,
  width int,
  height int,
  created_at timestamptz not null default now()
);

create index if not exists chat_messages_room_created_at_idx
  on public.chat_messages(room_id, created_at);

alter table public.chat_messages enable row level security;
alter table public.chat_messages replica identity full;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'chat_messages'
      and policyname = 'chat_messages_select'
  ) then
    create policy chat_messages_select
      on public.chat_messages
      for select
      to authenticated, anon
      using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'chat_messages'
      and policyname = 'chat_messages_insert'
  ) then
    create policy chat_messages_insert
      on public.chat_messages
      for insert
      to authenticated, anon
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'chat_messages'
      and policyname = 'chat_messages_update'
  ) then
    create policy chat_messages_update
      on public.chat_messages
      for update
      to authenticated, anon
      using (true)
      with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'chat_messages'
      and policyname = 'chat_messages_delete'
  ) then
    create policy chat_messages_delete
      on public.chat_messages
      for delete
      to authenticated, anon
      using (true);
  end if;
end $$;

insert into storage.buckets (id, name, public)
values ('chat', 'chat', true)
on conflict (id) do update
set name = excluded.name,
    public = excluded.public;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'chat_storage_select'
  ) then
    create policy chat_storage_select
      on storage.objects
      for select
      to authenticated
      using (bucket_id = 'chat');
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'chat_storage_insert'
  ) then
    create policy chat_storage_insert
      on storage.objects
      for insert
      to authenticated
      with check (bucket_id = 'chat');
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'chat_storage_update'
  ) then
    create policy chat_storage_update
      on storage.objects
      for update
      to authenticated
      using (bucket_id = 'chat')
      with check (bucket_id = 'chat');
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'chat_storage_delete'
  ) then
    create policy chat_storage_delete
      on storage.objects
      for delete
      to authenticated
      using (bucket_id = 'chat');
  end if;
end $$;

do $$
begin
  if exists (
    select 1
    from pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_messages'
  ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;
