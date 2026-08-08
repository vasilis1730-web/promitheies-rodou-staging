import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = fs.readFileSync(
  new URL('../supabase/migrations/202608050007_service_catalog.sql', import.meta.url),
  'utf8'
);

const schema = String.raw`
create role anon nologin;
create role authenticated nologin;

create table public.municipal_units (
  id smallserial primary key,
  name text not null,
  is_active boolean not null default true
);
create table public.procurement_groups (
  id smallserial primary key,
  code text not null unique,
  name text not null unique,
  short_name text not null,
  sort_order smallint not null unique,
  domain text not null check (domain in ('procurement', 'service')),
  is_active boolean not null default true
);
create table public.materials (
  id uuid primary key default gen_random_uuid(),
  group_id smallint not null references public.procurement_groups(id),
  code text unique,
  name text not null,
  short_name text,
  subcategory text,
  unit text not null,
  quantity_scale smallint not null,
  cpv text,
  technical_specs text,
  standards text,
  ce_required boolean not null default false,
  notes_for_tender text,
  default_unit_price numeric(14,4),
  is_active boolean not null default true,
  sort_order integer
);
create table public.material_aliases (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete cascade,
  alias text not null,
  source_note text,
  unique(material_id, alias)
);
create table public.tender_overrides (id text primary key, data jsonb);

create or replace function public.app_schema_version()
returns text language sql stable as $$ select '36.5.1'::text $$;

create or replace function public.app_unit_default_scale(p_unit text)
returns smallint language sql immutable as $$
  select case when p_unit in ('τεμ.', 'μήνας', 'ώρα') then 0 else 3 end::smallint
$$;
`;

async function scalar(db, sql) {
  const result = await db.query(sql);
  return Object.values(result.rows[0] || {})[0];
}

async function stagingFixture(procurementItems = 918) {
  const db = new PGlite();
  await db.exec(schema);
  await db.exec(`
    insert into public.municipal_units(name)
    select 'Μονάδα ' || n from generate_series(1, 11) n;

    insert into public.procurement_groups(code, name, short_name, sort_order, domain)
    select 'PROC' || lpad(n::text, 2, '0'), 'Ομάδα προμηθειών ' || n,
           'Προμήθειες ' || n, n, 'procurement'
      from generate_series(1, 14) n;

    insert into public.materials(
      group_id, code, name, unit, quantity_scale, default_unit_price, is_active, sort_order
    )
    select 1 + ((n - 1) % 14), 'MAT-' || lpad(n::text, 4, '0'),
           'Υλικό ' || n, 'τεμ.', 0, 1, true, n
      from generate_series(1, ${procurementItems}) n;
  `);
  return db;
}

test('η migration v36.5.5 εισάγει ακριβώς τον ελεγμένο κατάλογο και είναι επαναλήψιμη', async () => {
  const db = await stagingFixture();
  try {
    await db.exec(migration);

    assert.equal(await scalar(db, `select public.app_schema_version()`), '36.5.5');
    assert.equal(Number(await scalar(db, `select count(*) from public.procurement_groups where domain='service' and is_active`)), 8);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.materials m
      join public.procurement_groups g on g.id=m.group_id
      where g.domain='service' and m.is_active
    `)), 178);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.materials m
      join public.procurement_groups g on g.id=m.group_id
      where g.domain='service' and m.is_active
        and (nullif(btrim(m.cpv),'') is null
          or nullif(btrim(m.unit),'') is null
          or nullif(btrim(m.technical_specs),'') is null
          or nullif(btrim(m.standards),'') is null
          or m.default_unit_price is null)
    `)), 0);
    assert.equal(Number(await scalar(db, `select count(*) from public.material_aliases where alias='IMP-29-1783067314938-1'`)), 1);
    assert.equal(Number(await scalar(db, `select count(*) from public.materials where code='IMP-29-1783067314938-1'`)), 0);
    assert.equal(Number(await scalar(db, `select count(*) from public.tender_overrides`)), 0);
    assert.equal(await scalar(db, `select metadata->>'pricing_status' from public.app_catalog_migrations`), 'legacy_defaults_not_contract_verified');
    assert.match(await scalar(db, `select name from public.materials where code='SRV06-03'`), /δεκαετ/i);
    assert.doesNotMatch(await scalar(db, `select name from public.materials where code='SRV06-03'`), /πενταετ/i);
    assert.match(await scalar(db, `select name from public.materials where code='SRV07-07'`), /24 επισκέψεις/i);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.materials m
      join public.procurement_groups g on g.id=m.group_id
      where g.domain='service' and (coalesce(m.technical_specs,'') ~ '517/2014|2015/2067')
    `)), 0);

    await db.exec(migration);
    assert.equal(Number(await scalar(db, `select count(*) from public.procurement_groups where domain='service'`)), 8);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.materials m
      join public.procurement_groups g on g.id=m.group_id where g.domain='service'
    `)), 178);
    assert.equal(Number(await scalar(db, `select count(*) from public.app_catalog_migrations`)), 1);
  } finally {
    await db.close();
  }
});

test('ο προέλεγχος απορρίπτει μη αναμενόμενο staging και η συναλλαγή δεν αφήνει ίχνη', async () => {
  const db = await stagingFixture(917);
  try {
    await assert.rejects(db.exec(migration), /αναμένονται 918 ενεργά είδη προμηθειών/i);
    await db.exec('rollback');
    assert.equal(Number(await scalar(db, `select count(*) from public.procurement_groups where domain='service'`)), 0);
    assert.equal(await scalar(db, `select to_regclass('public.app_catalog_migrations') is null`), true);
    assert.equal(await scalar(db, `select public.app_schema_version()`), '36.5.1');
  } finally {
    await db.close();
  }
});
