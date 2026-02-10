-- Adds exclusive CMM specialist position used by the app.
insert into public.positions (id, name)
values ('cmm_specialist', 'CMM специалист')
on conflict (id) do update
set name = excluded.name;
