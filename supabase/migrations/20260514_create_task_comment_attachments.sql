-- Вложения к комментариям задач и приватный Storage bucket.

create table if not exists public.task_comment_attachments (
  id uuid primary key default gen_random_uuid(),
  task_id text not null,
  order_id text not null,
  stage_id text not null,
  comment_id text not null,
  user_id text,
  file_type text not null default 'file'
    check (file_type in ('image', 'video', 'audio', 'file')),
  file_name text not null,
  storage_path text not null unique,
  file_url text,
  mime_type text not null default 'application/octet-stream',
  size_bytes bigint not null default 0 check (size_bytes >= 0),
  created_at timestamptz not null default now()
);

create index if not exists task_comment_attachments_task_id_idx
  on public.task_comment_attachments(task_id);

create index if not exists task_comment_attachments_order_id_idx
  on public.task_comment_attachments(order_id);

create index if not exists task_comment_attachments_comment_id_idx
  on public.task_comment_attachments(comment_id);

create index if not exists task_comment_attachments_order_stage_idx
  on public.task_comment_attachments(order_id, stage_id);

alter table public.task_comment_attachments enable row level security;
alter table public.task_comment_attachments replica identity full;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'task_comment_attachments'
      and policyname = 'task_comment_attachments_select'
  ) then
    create policy task_comment_attachments_select
      on public.task_comment_attachments
      for select
      to authenticated, anon
      using (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'task_comment_attachments'
      and policyname = 'task_comment_attachments_insert'
  ) then
    create policy task_comment_attachments_insert
      on public.task_comment_attachments
      for insert
      to authenticated, anon
      with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'task_comment_attachments'
      and policyname = 'task_comment_attachments_update'
  ) then
    create policy task_comment_attachments_update
      on public.task_comment_attachments
      for update
      to authenticated, anon
      using (true)
      with check (true);
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'task_comment_attachments'
      and policyname = 'task_comment_attachments_delete'
  ) then
    create policy task_comment_attachments_delete
      on public.task_comment_attachments
      for delete
      to authenticated, anon
      using (true);
  end if;
end $$;

insert into storage.buckets (id, name, public)
values ('task-comment-attachments', 'task-comment-attachments', false)
on conflict (id) do update
set name = excluded.name,
    public = excluded.public;

do $$
begin
  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'task_comment_attachments_storage_select'
  ) then
    create policy task_comment_attachments_storage_select
      on storage.objects
      for select
      to authenticated, anon
      using (bucket_id = 'task-comment-attachments');
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'task_comment_attachments_storage_insert'
  ) then
    create policy task_comment_attachments_storage_insert
      on storage.objects
      for insert
      to authenticated, anon
      with check (bucket_id = 'task-comment-attachments');
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'task_comment_attachments_storage_update'
  ) then
    create policy task_comment_attachments_storage_update
      on storage.objects
      for update
      to authenticated, anon
      using (bucket_id = 'task-comment-attachments')
      with check (bucket_id = 'task-comment-attachments');
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'task_comment_attachments_storage_delete'
  ) then
    create policy task_comment_attachments_storage_delete
      on storage.objects
      for delete
      to authenticated, anon
      using (bucket_id = 'task-comment-attachments');
  end if;
end $$;

do $$
begin
  if exists (
    select 1 from pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'task_comment_attachments'
  ) then
    alter publication supabase_realtime add table public.task_comment_attachments;
  end if;
end $$;
