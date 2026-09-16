begin;

-- Keep the existing application roles working while removing the implicit
-- PUBLIC grant that would otherwise bypass the agent function allowlist.
grant execute on function public.task_shift_pause_users(jsonb)
  to anon, authenticated, service_role;
revoke execute on function public.task_shift_pause_users(jsonb) from public;

commit;
