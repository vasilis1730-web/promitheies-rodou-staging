import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const migration=fs.readFileSync(
  new URL('../supabase/migrations/202608090008_phase5_rls_privilege_hardening.sql',import.meta.url),
  'utf8'
);
const verifier=fs.readFileSync(
  new URL('../supabase/115_VERIFY_PHASE5_RLS_PRIVILEGE_HARDENING.sql',import.meta.url),
  'utf8'
);

test('Phase 5 κλείνει το current PUBLIC/anon function surface χωρίς blanket revoke του authenticated',()=>{
  assert.match(migration,/revoke\s+execute\s+on\s+all\s+functions\s+in\s+schema\s+public\s+from\s+public\s*,\s*anon\s*;/i);
  assert.doesNotMatch(migration,/revoke\s+execute\s+on\s+all\s+functions\s+in\s+schema\s+public\s+from[^;]*authenticated/i);
  assert.match(migration,/revoke\s+all\s+on\s+all\s+tables\s+in\s+schema\s+public\s+from\s+anon/i);
});

test('Phase 5 κάνει τα μελλοντικά postgres-owned app objects opt-in για browser roles',()=>{
  assert.match(migration,/alter\s+default\s+privileges\s+for\s+role\s+postgres\s+in\s+schema\s+public[\s\S]*revoke\s+execute\s+on\s+functions\s+from\s+public\s*,\s*anon\s*,\s*authenticated/i);
  assert.match(migration,/revoke\s+all\s+on\s+tables\s+from\s+anon\s*,\s*authenticated/i);
  assert.match(migration,/revoke\s+all\s+on\s+sequences\s+from\s+anon\s*,\s*authenticated/i);
});

test('Phase 5 αφαιρεί unused legacy browser surface και αφήνει το idempotency deny-by-default',()=>{
  assert.match(migration,/revoke\s+all\s+on\s+table\s+public\.mo_projects\s+from\s+anon\s*,\s*authenticated/i);
  assert.match(migration,/revoke\s+all\s+on\s+table\s+public\.mo_counters\s+from\s+anon\s*,\s*authenticated/i);
  assert.doesNotMatch(migration,/create\s+policy[\s\S]*app_operation_idempotency/i);
});

test('Phase 5 δεν αλλάζει το frontend compatibility schema version',()=>{
  assert.match(migration,/requires\s+schema\s+36\.6\.6|απαιτεί\s+schema\s+36\.6\.6/i);
  assert.doesNotMatch(migration,/create\s+or\s+replace\s+function\s+public\.app_schema_version/i);
});

test('Phase 5 verifier ελέγχει deny-by-default, views, defaults και resilient entrypoints',()=>{
  for(const marker of [
    'anon_has_no_public_table_access',
    'public_function_execute_is_zero',
    'anon_function_execute_is_zero',
    'security_definers_have_search_path',
    'exposed_views_are_security_invoker',
    'postgres_future_app_defaults_are_opt_in',
    'legacy_mo_projects_blocked',
    'legacy_mo_counters_blocked',
    'idempotency_direct_read_blocked',
    'resilient_save_still_callable',
    'resilient_lock_still_callable',
    'resilient_contract_still_callable',
    'resilient_order_still_callable',
    'resilient_excel_still_callable',
    'resilient_copy_still_callable',
    'resilient_template_load_still_callable',
    'phase5_privilege_hardening_ready'
  ]) assert.ok(verifier.includes(marker),marker);
});
