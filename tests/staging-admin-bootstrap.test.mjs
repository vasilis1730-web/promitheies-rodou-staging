import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const bootstrap = fs.readFileSync(
  new URL('../supabase/STAGING_SET_FIRST_ADMIN.sql', import.meta.url),
  'utf8'
);

const USER_ID = '00000000-0000-0000-0000-000000000001';
const OTHER_ID = '00000000-0000-0000-0000-000000000002';

async function newDb(version = '36.5.1') {
  const upgraded = version === '36.5.5' || version === '36.6.0' || version === '36.6.1';
  const groupCount = upgraded ? 22 : 14;
  const materialCount = upgraded ? 1096 : 918;
  const db = new PGlite();
  await db.exec(`
    create schema auth;
    create table auth.users (
      id uuid primary key,
      email text,
      email_confirmed_at timestamptz
    );
    create function public.app_schema_version() returns text
      language sql stable as $$ select '${version}'::text $$;
    create table public.municipal_units (id integer primary key);
    create table public.procurement_groups (id integer primary key);
    create table public.materials (id integer primary key);
    create table public.profiles (
      id uuid primary key references auth.users(id),
      role text not null,
      municipal_unit_id integer,
      updated_at timestamptz not null default now()
    );
    create table public.user_app_permissions (
      user_id uuid primary key references auth.users(id),
      can_supervise boolean not null default false,
      updated_at timestamptz not null default now(),
      updated_by uuid references auth.users(id)
    );
    create table public.unit_requests (id bigint primary key);
    create table public.locked_studies (id bigint primary key);
    create table public.mo_contracts (id bigint primary key);
    create table public.mo_orders (id bigint primary key);
    insert into public.municipal_units select i from generate_series(1,11) i;
    insert into public.procurement_groups select i from generate_series(1,${groupCount}) i;
    insert into public.materials select i from generate_series(1,${materialCount}) i;
  `);
  return db;
}

test('το staging bootstrap αποδίδει admin μόνο στον μοναδικό επιβεβαιωμένο χρήστη', async () => {
  const db = await newDb();
  try {
    await db.exec(`
      insert into auth.users(id,email,email_confirmed_at)
      values ('${USER_ID}','viewer@example.test',now());
      insert into public.profiles(id,role,municipal_unit_id)
      values ('${USER_ID}','viewer',null);
    `);
    await db.exec(bootstrap);
    const profile = (await db.query(`
      select p.role,p.municipal_unit_id,ap.can_supervise
      from public.profiles p
      join public.user_app_permissions ap on ap.user_id=p.id
    `)).rows[0];
    assert.deepEqual(profile, { role: 'admin', municipal_unit_id: null, can_supervise: true });
  } finally {
    await db.close();
  }
});

test('το staging bootstrap αναγνωρίζει και καθαρό staging μετά τη migration v36.5.5', async () => {
  const db = await newDb('36.5.5');
  try {
    await db.exec(`
      insert into auth.users(id,email,email_confirmed_at)
      values ('${USER_ID}','viewer@example.test',now());
      insert into public.profiles(id,role,municipal_unit_id)
      values ('${USER_ID}','viewer',null);
    `);
    await db.exec(bootstrap);
    assert.equal((await db.query(`select role from public.profiles where id='${USER_ID}'`)).rows[0].role, 'admin');
  } finally {
    await db.close();
  }
});

test('το staging bootstrap αναγνωρίζει και καθαρό staging v36.6.1', async () => {
  const db = await newDb('36.6.1');
  try {
    await db.exec(`
      insert into auth.users(id,email,email_confirmed_at)
      values ('${USER_ID}','viewer@example.test',now());
      insert into public.profiles(id,role,municipal_unit_id)
      values ('${USER_ID}','viewer',null);
    `);
    await db.exec(bootstrap);
    assert.equal((await db.query(`select role from public.profiles where id='${USER_ID}'`)).rows[0].role, 'admin');
  } finally {
    await db.close();
  }
});

test('το staging bootstrap απορρίπτει περισσότερους από έναν χρήστες', async () => {
  const db = await newDb();
  try {
    await db.exec(`
      insert into auth.users(id,email,email_confirmed_at) values
        ('${USER_ID}','one@example.test',now()),
        ('${OTHER_ID}','two@example.test',now());
      insert into public.profiles(id,role,municipal_unit_id) values
        ('${USER_ID}','viewer',null),
        ('${OTHER_ID}','viewer',null);
    `);
    await assert.rejects(db.exec(bootstrap), /ακριβώς ένας δοκιμαστικός χρήστης/i);
  } finally {
    await db.close();
  }
});

test('το staging bootstrap απορρίπτει project με πραγματική κίνηση', async () => {
  const db = await newDb();
  try {
    await db.exec(`
      insert into auth.users(id,email,email_confirmed_at)
      values ('${USER_ID}','viewer@example.test',now());
      insert into public.profiles(id,role,municipal_unit_id)
      values ('${USER_ID}','viewer',null);
      insert into public.unit_requests(id) values (1);
    `);
    await assert.rejects(db.exec(bootstrap), /project δεν είναι πλέον κενό/i);
  } finally {
    await db.close();
  }
});

test('το staging bootstrap απορρίπτει διαφορετικό schema ή κατάλογο', async () => {
  const db = await newDb();
  try {
    await db.exec(`
      insert into auth.users(id,email,email_confirmed_at)
      values ('${USER_ID}','viewer@example.test',now());
      insert into public.profiles(id,role,municipal_unit_id)
      values ('${USER_ID}','viewer',null);
      delete from public.materials where id = 918;
    `);
    await assert.rejects(db.exec(bootstrap), /δεν αναγνωρίστηκε το αναμενόμενο κενό staging/i);
  } finally {
    await db.close();
  }
});
