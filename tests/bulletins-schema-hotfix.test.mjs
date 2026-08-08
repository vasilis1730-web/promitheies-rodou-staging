import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = fs.readFileSync(
  new URL('../supabase/migrations/202608060003_fix_mo_orders_study_column.sql', import.meta.url),
  'utf8'
);
const installer = fs.readFileSync(
  new URL('../supabase/00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql', import.meta.url),
  'utf8'
);

async function scalar(db, sql) {
  const result = await db.query(sql);
  const row = result.rows[0] || {};
  return row[Object.keys(row)[0]];
}

test('το legacy source_study_id μετονομάζεται σε study_id χωρίς απώλεια και το hotfix είναι επαναλήψιμο', async () => {
  const db = new PGlite();
  try {
    await db.exec(`
      create table public.locked_studies (id uuid primary key);
      create table public.mo_orders (
        id uuid primary key,
        source_study_id uuid references public.locked_studies(id) on delete restrict
      );
      create index idx_mo_orders_study on public.mo_orders(source_study_id);
      create or replace function public.app_schema_version()
      returns text language sql stable as $$ select '36.5.5'::text $$;
      insert into public.locked_studies(id)
      values ('00000000-0000-0000-0000-000000000001');
      insert into public.mo_orders(id,source_study_id)
      values (
        '00000000-0000-0000-0000-000000000002',
        '00000000-0000-0000-0000-000000000001'
      );
    `);

    await db.exec(migration);
    await db.exec(migration);

    assert.equal(Number(await scalar(db, `
      select count(*) from information_schema.columns
      where table_schema='public' and table_name='mo_orders' and column_name='study_id'
    `)), 1);
    assert.equal(Number(await scalar(db, `
      select count(*) from information_schema.columns
      where table_schema='public' and table_name='mo_orders' and column_name='source_study_id'
    `)), 0);
    assert.equal(await scalar(db, `select study_id::text from public.mo_orders`),
      '00000000-0000-0000-0000-000000000001');
    assert.ok(Number(await scalar(db, `
      select count(*)
      from pg_constraint c
      join unnest(c.conkey) as key(attnum) on true
      join pg_attribute a on a.attrelid=c.conrelid and a.attnum=key.attnum
      where c.conrelid='public.mo_orders'::regclass
        and c.confrelid='public.locked_studies'::regclass
        and c.contype='f' and a.attname='study_id'
    `)) >= 1);
  } finally {
    await db.close();
  }
});

test('το πλήρες installer χρησιμοποιεί το ίδιο canonical πεδίο με frontend και atomic workflows', () => {
  const table = installer.match(/create table if not exists public\.mo_orders \([\s\S]*?\n\);/i)?.[0] || '';
  assert.match(table, /\bstudy_id uuid\b/);
  assert.doesNotMatch(table, /\bsource_study_id uuid\b/);
  assert.match(installer, /on public\.mo_orders\(study_id\)/);
  assert.match(installer, /comment on column public\.mo_orders\.study_id/);
});
