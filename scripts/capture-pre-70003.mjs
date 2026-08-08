import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const root = fileURLToPath(new URL('../', import.meta.url));
const migrationsDir = path.join(root, 'supabase', 'migrations');
const out = path.join(root, 'ci-pre-70003-diagnostics.json');
const report = { generated_at: new Date().toISOString(), variants: [] };

function clean(sql) { return sql.replace(/create extension if not exists pgcrypto;?/gi, ''); }

async function setupDb() {
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
  await db.exec(clean(fs.readFileSync(path.join(root, 'supabase', '00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql'), 'utf8')));
  const migrations = fs.readdirSync(migrationsDir)
    .filter(n => /^\d+.*\.sql$/i.test(n) && n < '202608070003_security_hardening.sql')
    .sort((a,b) => a.localeCompare(b, 'en'));
  for (const name of migrations) {
    await db.exec(clean(fs.readFileSync(path.join(migrationsDir, name), 'utf8')));
  }
  return db;
}

async function testVariant(label, sql) {
  const db = await setupDb();
  const item = { label };
  try {
    await db.exec(sql);
    item.ok = true;
  } catch (e) {
    item.ok = false;
    item.error = e?.message || String(e);
    try { await db.exec('rollback'); } catch {}
  }
  try {
    item.rls_auto_enable = (await db.query(`select count(*)::int as n from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='rls_auto_enable'`)).rows[0]?.n;
    item.rls_policy_templates = (await db.query(`select to_regclass('public.rls_policy_templates')::text as rel`)).rows[0]?.rel ?? null;
  } catch (e) {
    item.postcheck_error = e?.message || String(e);
  }
  report.variants.push(item);
  await db.close();
}

const full = clean(fs.readFileSync(path.join(migrationsDir, '202608070003_security_hardening.sql'), 'utf8'));
const noWrapper = full.replace(/^\s*begin\s*;?/im, '').replace(/\bcommit\s*;\s*$/im, '');
const onlyViewTxn = `begin; alter view public.v_specs_coverage set (security_invoker = true); commit;`;
const noViewTxn = full.replace(/do \$\$\nbegin\n  if to_regclass\('public\.v_specs_coverage'\)[\s\S]*?end \$\$;/m, '');

await testVariant('whole 70003 exactly as migration', full);
await testVariant('same statements without BEGIN/COMMIT wrapper', noWrapper);
await testVariant('ALTER VIEW security_invoker alone inside transaction', onlyViewTxn);
await testVariant('whole transaction without ALTER VIEW block', noViewTxn);

fs.writeFileSync(out, JSON.stringify(report, null, 2));
