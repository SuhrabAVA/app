import assert from 'node:assert/strict';
import test from 'node:test';
import { PgParser } from '@supabase/pg-parser';
import { validateSql } from '../../../supabase/agent_brain/functions/db-analyst/sql_validator.mjs';

const parser = new PgParser({ version: 17 });
const basePolicy = {
  allowedSchemas: ['public'],
  allowedObjects: {
    orders: { requiresGoldenQuery: false },
    tasks: { requiresGoldenQuery: true },
    employees: { sensitive: true },
  },
  allowedFunctions: ['public.data_health_report'],
  maxRows: 200,
};

async function verdict(sql, overrides = {}) {
  return validateSql(sql, { ...basePolicy, ...overrides }, parser);
}

test('allows a bounded select', async () => {
  assert.equal((await verdict('select id from public.orders limit 10')).allowed, true);
});

test('allows an aggregate without limit', async () => {
  assert.equal((await verdict('select count(*) from public.orders')).allowed, true);
});

test('allows a safe CTE', async () => {
  assert.equal((await verdict('with x as (select id from public.orders) select * from x limit 10')).allowed, true);
});

test('allows whitelisted function through a golden query', async () => {
  const result = await verdict('select public.data_health_report() limit 200', {
    goldenQueryCode: 'GQ-DATA-HEALTH-SUMMARY',
  });
  assert.equal(result.allowed, true);
});

test('allows EXPLAIN without ANALYZE', async () => {
  assert.equal((await verdict('explain select id from public.orders limit 10')).allowed, true);
});

const rejected = [
  ['select id from public.orders limit 1;', 'SEMICOLON_FORBIDDEN'],
  ['select 1; select 2', 'SEMICOLON_FORBIDDEN'],
  ['insert into public.orders(id) values (gen_random_uuid())', 'NOT_SELECT'],
  ['with x as (delete from public.orders returning id) select * from x limit 1', 'MUTATING_STATEMENT'],
  ['select id from public.unknown_table limit 1', 'OBJECT_NOT_ALLOWED'],
  ['select public.unknown_function() limit 1', 'FUNCTION_NOT_ALLOWED'],
  ['select pg_sleep(1) limit 1', 'FUNCTION_FORBIDDEN'],
  ['select id from public.orders for update', 'ROW_LOCK'],
  ['select * from public.employees limit 10', 'STAR_ON_SENSITIVE_OBJECT'],
  ['select id from public.orders', 'LIMIT_REQUIRED'],
  ['select id from public.orders limit 201', 'LIMIT_TOO_HIGH'],
  ['select id from public.tasks limit 10', 'GOLDEN_QUERY_REQUIRED'],
  ['explain analyze select id from public.orders limit 10', 'EXPLAIN_ANALYZE'],
];

for (const [sql, code] of rejected) {
  test(`rejects ${code}`, async () => {
    const result = await verdict(sql);
    assert.equal(result.allowed, false);
    assert.equal(result.code, code);
  });
}
