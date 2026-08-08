/*
 * PRODUCTION READINESS — v36.6.3
 *
 * Η δοκιμή ΔΕΝ διατηρεί χειροκίνητη λίστα migrations. Διαβάζει όλα τα .sql
 * από supabase/migrations ταξινομημένα, ώστε κάθε νέα migration να μπαίνει
 * αυτόματα στον clean-install έλεγχο.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID = '11111111-1111-1111-1111-111111111111';
const migrationsDir = fileURLToPath(new URL('../supabase/migrations/', import.meta.url));

function read(relative) {
  return fs.readFileSync(new URL(relative, import.meta.url), 'utf8');
}

function allMigrationFiles() {
  return fs.readdirSync(migrationsDir)
    .filter(name => /^\d+.*\.sql$/i.test(name))
    .sort((a, b) => a.localeCompare(b, 'en'));
}

async function scalar(db, sql, params = []) {
  const result = await db.query(sql, params);
  const row = result.rows[0] || {};
  return row[Object.keys(row)[0]];
}

async function migrationFailureDiagnostics(db) {
  try { await db.exec('rollback'); } catch {}
  const diagnostics = {};
  try {
    const fn = await db.query(`
      select p.proname, p.prosecdef, p.proconfig, p.prosrc
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='rls_auto_enable'
    `);
    diagnostics.rls_auto_enable = fn.rows;
  } catch (error) {
    diagnostics.rls_auto_enable_error = error?.message || String(error);
  }
  try {
    const triggers = await db.query(`
      select e.evtname, e.evtevent, e.evtenabled, e.evttags,
             p.proname as function_name
      from pg_event_trigger e
      join pg_proc p on p.oid=e.evtfoid
      order by e.evtname
    `);
    diagnostics.event_triggers = triggers.rows;
  } catch (error) {
    diagnostics.event_trigger_error = error?.message || String(error);
  }
  try {
    diagnostics.rls_policy_templates = await scalar(db,
      `select to_regclass('public.rls_policy_templates')::text`);
  } catch (error) {
    diagnostics.rls_policy_templates_error = error?.message || String(error);
  }
  return diagnostics;
}

async function installAll() {
  const db = new PGlite();
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin;
    create schema auth;
    create table auth.users (
      id uuid primary key default gen_random_uuid(), email text,
      raw_user_meta_data jsonb default '{}'::jsonb,
      encrypted_password text, email_confirmed_at timestamptz
    );
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('app.uid', true), '')::uuid
    $$;
    create function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
    create schema if not exists extensions;
  `);

  await db.exec(read('../supabase/00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql')
    .replace(/create extension if not exists pgcrypto;?/gi, ''));

  for (const name of allMigrationFiles()) {
    const sql = fs.readFileSync(path.join(migrationsDir, name), 'utf8')
      .replace(/create extension if not exists pgcrypto;?/gi, '');
    try {
      await db.exec(sql);
    } catch (error) {
      const diagnostics = await migrationFailureDiagnostics(db);
      throw new Error(
        `Migration ${name} failed: ${error?.message || error}\nDiagnostics: ${JSON.stringify(diagnostics)}`,
        { cause: error }
      );
    }
  }

  await db.exec(`
    insert into auth.users(id, email)
    values ('${ADMIN_ID}', 'admin@rhodes.gr');
    insert into public.profiles(id, role, municipal_unit_id, full_name, email, is_active)
    values ('${ADMIN_ID}', 'admin', null, 'Διαχειριστής', 'admin@rhodes.gr', true)
    on conflict (id) do update set role = 'admin', is_active = true;
    select set_config('app.uid', '${ADMIN_ID}', false);
  `);

  return db;
}

test('clean install εφαρμόζει αυτόματα ΟΛΕΣ τις migrations και φτάνει σε schema 36.6.3', async () => {
  const db = await installAll();
  try {
    const migrations = allMigrationFiles();
    assert.ok(migrations.includes('202608070002_technical_specs_transfer.sql'));
    assert.ok(migrations.includes('202608070003_security_hardening.sql'));
    assert.ok(migrations.includes('202608080001_v36_6_3_authorization_readiness.sql'));

    assert.equal(await scalar(db, `select public.app_schema_version()`), '36.6.3');
    assert.equal(await scalar(db,
      `select to_regprocedure('public.apply_technical_specs_import()') is not null`), true);
    assert.equal(await scalar(db,
      `select to_regclass('public.v_specs_coverage') is not null`), true);
  } finally {
    await db.close();
  }
});

test('inactive profile χάνει role, unit και supervisor/admin authorization', async () => {
  const db = await installAll();
  try {
    await db.exec(`
      insert into public.user_app_permissions(user_id, can_supervise)
      values ('${ADMIN_ID}', true)
      on conflict (user_id) do update set can_supervise = true;
    `);

    assert.equal(await scalar(db, `select public.app_user_is_active()`), true);
    assert.equal(await scalar(db, `select public.app_current_role()`), 'admin');
    assert.equal(await scalar(db, `select public.app_is_admin()`), true);
    assert.equal(await scalar(db, `select public.app_can_supervise()`), true);

    await db.exec(`update public.profiles set is_active = false where id = '${ADMIN_ID}'`);

    assert.equal(await scalar(db, `select public.app_user_is_active()`), false);
    assert.equal(await scalar(db, `select public.app_current_role() is null`), true);
    assert.equal(await scalar(db, `select public.app_current_unit_id() is null`), true);
    assert.equal(await scalar(db, `select public.app_is_admin()`), false);
    assert.equal(await scalar(db, `select public.app_can_supervise()`), false);
  } finally {
    await db.close();
  }
});

test('restrictive RLS guard κόβει table SELECT σε inactive authenticated caller', async () => {
  const db = await installAll();
  try {
    const expectedUnits = Number(await scalar(db, `select count(*) from public.municipal_units`));
    assert.ok(expectedUnits > 0);

    await db.exec(`set role authenticated`);
    assert.equal(Number(await scalar(db, `select count(*) from public.municipal_units`)), expectedUnits);
    await db.exec(`reset role`);

    await db.exec(`update public.profiles set is_active = false where id = '${ADMIN_ID}'`);

    await db.exec(`set role authenticated`);
    assert.equal(Number(await scalar(db, `select count(*) from public.municipal_units`)), 0);
    assert.equal(Number(await scalar(db, `select count(*) from public.profiles`)), 0);
    await db.exec(`reset role`);
  } finally {
    try { await db.exec(`reset role`); } catch {}
    await db.close();
  }
});
