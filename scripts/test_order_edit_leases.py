"""Integration test against an ISOLATED local PostgreSQL 17 cluster only.

Start a disposable cluster on 127.0.0.1:55439. This creates minimal prerequisite
tables, applies the real migration, and uses independent DB connections to race
editors. Never connects to the application's database or reads .env.
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier
from uuid import uuid4
import json
import psycopg2

ROOT = Path(__file__).resolve().parents[1]
DSN = 'host=127.0.0.1 port=55439 dbname=postgres user=postgres connect_timeout=5'
USER = str(uuid4())  # Same Supabase user on every device, intentionally.


def connect():
    conn = psycopg2.connect(DSN)
    conn.autocommit = True
    return conn


admin = connect()
with admin.cursor() as c:
    c.execute('show data_directory')
    actual = Path(c.fetchone()[0]).resolve()
    assert actual == (ROOT / '.dart_tool/order-lock-pg-local').resolve(), actual
    c.execute('''
      -- This cluster is disposable, verified above; make reruns deterministic.
      drop schema if exists order_edit_private cascade;
      drop schema if exists auth cascade;
      drop schema public cascade;
      create schema public;
      grant usage on schema public to public;
      drop role if exists authenticated;
      drop role if exists anon;
      create role authenticated; create role anon;
      create schema auth;
      create function auth.uid() returns uuid language sql stable as
        $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
      grant usage on schema auth to authenticated;
      create table public.orders(id uuid primary key, manager text, customer text,
        product jsonb, status text, actual_qty numeric, updated_at timestamptz);
      create table public.order_paints(id uuid primary key, order_id uuid references orders(id), name text);
      create table public.order_files(id uuid primary key, order_id uuid references orders(id));
      create table public.production_plans(id uuid primary key, order_id uuid references orders(id));
      create table public.prod_plans(id uuid primary key, order_id uuid references orders(id));
      create table public.prod_plan_stages(id uuid primary key, plan_id uuid references prod_plans(id),
        template_stage_id uuid, seq integer, name text, note text, position_id text, workplace_id text,
        stage_id text, stage_group_key text, step_no integer, status text);
      grant select,insert,update,delete on all tables in schema public to authenticated;
    ''')
    c.execute((ROOT / 'supabase/migrations/20260916064742_order_edit_leases.sql').read_text(encoding='utf-8'))


def client():
    conn = connect()
    with conn.cursor() as c:
        c.execute('set role authenticated')
        c.execute("select set_config('request.jwt.claim.sub',%s,false)", (USER,))
    return conn


def query(conn, sql, args=()):
    with conn.cursor() as c:
        c.execute(sql, args)
        return c.fetchone()[0] if c.description else None


def headers(conn, oid, token):
    value = {} if token is None else {'x-order-edit-tokens': json.dumps({oid: token})}
    query(conn, "select set_config('request.headers',%s,false)", (json.dumps(value),))


def acquire(conn, oid, token):
    return query(conn, 'select public.acquire_order_edit(%s,%s,%s)', (oid, token, 'Test editor'))['acquired']


def blocked(conn, sql, args):
    try:
        query(conn, sql, args)
    except psycopg2.Error as exc:
        assert exc.pgcode == '55P03', exc
    else:
        raise AssertionError('A conflicting write was accepted')


a, b = client(), client()
oid, ta, tb = str(uuid4()), str(uuid4()), str(uuid4())
query(admin, 'insert into orders(id,manager,customer) values(%s,%s,%s)', (oid, 'Manager', 'Before'))
assert acquire(a, oid, ta)
assert not acquire(b, oid, tb)
blocked(b, 'update orders set customer=%s where id=%s', ('Lost update', oid))
blocked(b, 'insert into order_paints(id,order_id,name) values(%s,%s,%s)', (str(uuid4()), oid, 'Paint'))
headers(a, oid, ta)
query(a, 'update orders set manager=manager,customer=%s where id=%s', ('Saved by A', oid))
assert query(a, 'select public.renew_order_edit(%s,%s)', (oid, ta))
query(b, 'select public.release_order_edit(%s,%s)', (oid, tb))
assert not acquire(b, oid, tb)
# Production counters keep working while a manager edits the order.
query(b, 'update orders set actual_qty=10 where id=%s', (oid,))
query(a, 'select public.release_order_edit(%s,%s)', (oid, ta))
assert acquire(b, oid, tb)
headers(b, oid, tb)
assert query(b, 'select customer from orders where id=%s', (oid,)) == 'Saved by A'
query(a, 'select public.release_order_edit(%s,%s)', (oid, ta))
assert query(b, 'select public.renew_order_edit(%s,%s)', (oid, tb))
blocked(a, 'update orders set manager=manager,customer=%s where id=%s', ('Stale A', oid))
query(admin, "update order_edit_private.leases set expires_at=clock_timestamp()-interval '1 second' where order_id=%s", (oid,))
assert not query(b, 'select public.renew_order_edit(%s,%s)', (oid, tb))
blocked(b, 'update orders set customer=%s where id=%s', ('Expired B', oid))
headers(b, oid, None)
blocked(b, 'update orders set manager=manager,customer=%s where id=%s', ('Old build', oid))
assert query(admin, 'select customer from orders where id=%s', (oid,)) == 'Saved by A'
assert acquire(a, oid, ta)
headers(a, oid, ta)
plan_id, stage_id = str(uuid4()), str(uuid4())
query(a, 'insert into prod_plans(id,order_id) values(%s,%s)', (plan_id, oid))
query(a, 'insert into prod_plan_stages(id,plan_id,name) values(%s,%s,%s)', (stage_id, plan_id, 'Stage'))
blocked(b, 'update prod_plan_stages set name=%s where id=%s', ('Other route', stage_id))
query(b, 'update prod_plan_stages set status=%s where id=%s', ('completed', stage_id))
query(b, 'update orders set status=%s where id=%s', ('completed', oid))
query(a, 'update orders set manager=manager,status=%s where id=%s', ('in_production', oid))
assert query(a, 'select status from orders where id=%s', (oid,)) == 'completed'
print('PASS: exclusion, authenticated shared identity, write fencing, child writes, ownership, release, expiry, legacy snapshots')
print('PASS: route editing is locked; stage execution and order completion are preserved')
# RLS and grants hide the secret capabilities even from the shared app role.
for sql in ('select token from order_edit_private.leases',
            "select order_edit_private.check_write('" + oid + "')"):
    try:
        query(a, sql)
    except psycopg2.Error as exc:
        assert exc.pgcode == '42501', exc
    else:
        raise AssertionError('Private lock capability exposed')
assert query(admin, "select has_function_privilege('anon','public.acquire_order_edit(uuid,uuid,text)','execute')") is False
assert query(admin, "select has_function_privilege('anon','public.active_order_edits()','execute')") is False
print('PASS: authenticated clients cannot read tokens or call internal checks; anon cannot acquire or list')


# Race two first acquisitions, without relying on a preexisting lease row.
for iteration in range(20):
    race_id = str(uuid4())
    query(admin, 'insert into orders(id) values(%s)', (race_id,))
    barrier = Barrier(2)

    def race(_):
        conn = client()
        try:
            barrier.wait(timeout=5)
            return acquire(conn, race_id, str(uuid4()))
        finally:
            conn.close()

    with ThreadPoolExecutor(max_workers=2) as pool:
        assert sorted(pool.map(race, range(2))) == [False, True]
print('PASS: 20 simultaneous first-acquisition races, exactly one winner each')

for conn in (a, b, admin):
    conn.close()
