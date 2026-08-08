import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const root = fileURLToPath(new URL('../', import.meta.url));
const migrationsDir = path.join(root, 'supabase', 'migrations');
const out = path.join(root, 'ci-pre-70003-diagnostics.json');
const db = new PGlite();
const report = { generated_at: new Date().toISOString(), setup: [], state: {}, statements: [] };

function clean(sql) {
  return sql.replace(/create extension if not exists pgcrypto;?/gi, '');
}
async function rows(sql) { return (await db.query(sql)).rows; }
async function run(label, sql) {
  try {
    await db.exec(sql);
    report.statements.push({ label, ok: true });
  } catch (e) {
    report.statements.push({ label, ok: false, error: e?.message || String(e) });
    try { await db.exec('rollback'); } catch {}
  }
}

try {
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

  const installer = fs.readFileSync(path.join(root, 'supabase', '00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql'), 'utf8');
  await db.exec(clean(installer));
  report.setup.push('installer');

  const migrations = fs.readdirSync(migrationsDir)
    .filter(n => /^\d+.*\.sql$/i.test(n) && n < '202608070003_security_hardening.sql')
    .sort((a,b) => a.localeCompare(b, 'en'));
  for (const name of migrations) {
    await db.exec(clean(fs.readFileSync(path.join(migrationsDir, name), 'utf8')));
    report.setup.push(name);
  }

  report.state.rls_auto_enable = await rows(`
    select n.nspname as schema_name, p.proname, p.prosecdef, p.proconfig, p.prosrc
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where p.proname='rls_auto_enable'
  `);
  report.state.functions_referencing_rls_policy_templates = await rows(`
    select n.nspname as schema_name, p.proname, p.prosrc
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where lower(coalesce(p.prosrc,'')) like '%rls_policy_templates%'
  `);
  try {
    report.state.event_triggers = await rows(`
      select e.evtname, e.evtevent, e.evtenabled, e.evttags, p.proname as function_name
      from pg_event_trigger e join pg_proc p on p.oid=e.evtfoid order by e.evtname
    `);
  } catch (e) {
    report.state.event_triggers_error = e?.message || String(e);
  }
  report.state.rls_policy_templates = await rows(`select to_regclass('public.rls_policy_templates')::text as relation`);
  report.state.v_specs_coverage = await rows(`select to_regclass('public.v_specs_coverage')::text as relation`);

  await run('alter v_specs_coverage security_invoker', `alter view public.v_specs_coverage set (security_invoker = true)`);
  await run('revoke app_generic_audit_trigger', `revoke all on function public.app_generic_audit_trigger() from public, anon, authenticated`);
  await run('revoke set_updated_at', `revoke all on function public.set_updated_at() from public, anon, authenticated`);
  await run('conditional rls_auto_enable hardening', `do $$ begin if to_regprocedure('public.rls_auto_enable()') is not null then revoke all on function public.rls_auto_enable() from public, anon, authenticated; alter function public.rls_auto_enable() set search_path = public, pg_temp; end if; end $$`);

  const alters = [
    `alter function public.set_updated_at() set search_path = public, pg_temp`,
    `alter function public.app_generic_audit_trigger() set search_path = public, pg_temp`,
    `alter function public.app_greek_key(text) set search_path = public, pg_temp`,
    `alter function public.app_unit_key(text) set search_path = public, pg_temp`,
    `alter function public.app_unit_default_scale(text) set search_path = public, pg_temp`,
    `alter function public.app_quantity_matches_scale(numeric, smallint) set search_path = public, pg_temp`,
    `alter function public.app_rhodes_award_group_no(bigint) set search_path = public, pg_temp`,
    `alter function public.app_rhodes_award_group_no(text, text) set search_path = public, pg_temp`,
    `alter function public.app_rhodes_award_group_name(integer) set search_path = public, pg_temp`,
    `alter function public.app_rhodes_municipal_unit_code(text, text) set search_path = public, pg_temp`
  ];
  for (const sql of alters) await run(sql, sql);
} catch (e) {
  report.fatal = e?.message || String(e);
} finally {
  fs.writeFileSync(out, JSON.stringify(report, null, 2));
  await db.close();
}
