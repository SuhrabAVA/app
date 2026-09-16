begin;
create temporary table verified_form_repair_baseline on commit drop as
select id, md5((to_jsonb(o) - array['form_id','new_form_no','form_series','form_code','updated_at'])::text) fingerprint
from public.orders o;
with candidates as (
select o.id, f.id form_id, o.customer, o.new_form_no, f.series
from public.orders o join public.forms f on f.number=o.new_form_no
where o.has_form and o.form_id is null
  and (select count(*) from public.forms nf where nf.number=o.new_form_no)=1
  and (
    lower(btrim(o.customer))=lower(btrim(f.series))
    or (
      o.customer in ('огонек - Бургер с огоньком','огонек - Бургеры с огоньком')
      and btrim(f.series) in ('огонек','огонек бургер')
      and (
        (f.number=1923 and f.size='13*10*5' and (o.product->>'width')::numeric=13 and (o.product->>'height')::numeric=10 and (o.product->>'depth')::numeric=5)
        or (f.number=1924 and f.size='32*42' and (o.product->>'width')::numeric=32 and (o.product->>'height')::numeric=42 and (o.product->>'depth')::numeric=0)
        or (f.number=1922 and f.size='29*22*12' and (o.product->>'width')::numeric=29 and (o.product->>'height')::numeric=22 and (o.product->>'depth')::numeric=12)
      )
    )
  )
)
update public.orders o set form_id=c.form_id from candidates c
where o.id=c.id and o.form_id is null;
do $$
begin
  if exists (
    select 1 from verified_form_repair_baseline b
    left join public.orders o on o.id=b.id
    where o.id is null or b.fingerprint is distinct from
      md5((to_jsonb(o) - array['form_id','new_form_no','form_series','form_code','updated_at'])::text)
  ) then raise exception 'Unrelated order data changed; repair aborted'; end if;
end;
$$;
commit;
select count(*) filter(where form_id is not null) linked,
count(*) filter(where has_form and form_id is null) unresolved
from public.orders;
