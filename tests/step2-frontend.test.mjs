import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');

const criticalTables = [
  'unit_requests',
  'request_lines',
  'locked_studies',
  'mo_contracts',
  'mo_contract_items',
  'mo_orders',
  'mo_order_items'
];

const resilientRpcs = [
  'save_unit_request_resilient_atomic',
  'copy_unit_request_resilient_atomic',
  'secure_import_catalog_request_resilient_atomic',
  'lock_study_resilient_atomic',
  'save_contract_pricing_resilient_atomic',
  'save_order_resilient_atomic',
  'load_study_template_resilient_atomic'
];

const directRpcs = [
  'issue_excel_export_token',
  'amend_locked_study_atomic',
  'cancel_locked_study_atomic',
  'transition_order_status_atomic',
  'delete_order_draft_atomic',
  'save_locked_study_as_template_atomic',
  'delete_study_template_atomic',
  'admin_purge_locked_study_atomic',
  'admin_set_app_permissions',
  'app_schema_version',
  'get_contract_balance_atomic'
];

test('το frontend v36.6.6 χρησιμοποιεί πραγματικές συμβατικές τιμές, ατομικές ροές και ασφαλή HTML sinks', () => {
  assert.match(source, /Προμήθειες &amp; Υπηρεσίες v36\.6\.6 PRODUCTION RESILIENCE/);
  assert.match(source, /const APP_VERSION='v36\.6\.6-production-resilience', REQUIRED_SCHEMA_VERSION='36\.6\.6'/);
  assert.match(source, /Ιαλυσού – Καλλιθέας – Αφάντου/);
  assert.match(source, /Λίνδου – Νότιας Ρόδου – Αρχαγγέλου/);
  assert.match(source, /Πεταλουδών – Καμείρου – Ατταβύρου/);
  assert.match(source, /\/νοτια\[σς\]\?ροδο\//);
  assert.match(source, /\/ατ\{1,2\}αβυρ\//);
  assert.match(source, /function renderAwardGroupLegend\s*\(/);
  assert.match(source, /function renderNoCatalogState\s*\(/);
  assert.match(source, /if\(cur\.groupId==null\)\{renderNoCatalogState\(\);return;\}/);
  assert.match(source, /p_direct_award_cap:DEFAULT_DIRECT_AWARD_CAP/);
  assert.doesNotMatch(source, /#agMembershipRows select\[data-unit-id\]/);
  assert.match(source, /from\('user_app_permissions'\)/);
  assert.match(source, /quantity_scale/);
  assert.match(source, /defaultQuantityScaleForUnit/);
  assert.match(source, /const sameId=/);
  assert.match(source, /function balanceItem/);
  assert.match(source, /if\(st\.unitId\)\{await selectUnit\(st\.unitId,true\);return;\}/);
  assert.match(source, /function invalidateAfterLock/);
  assert.match(source, /function saveStudyAsTemplate/);
  assert.match(source, /function loadStudyTemplate/);
  assert.match(source, /function purgeLockedStudy/);
  assert.match(source, /data-act="purge"/);
  assert.match(source, /\+\(admin\?\('<button class="mini mini--purge"/);
  assert.match(source, /πληκτρολογήστε ακριβώς: ΔΙΑΓΡΑΦΗ/);
  assert.match(source, /MO\.invalidateAfterLock\(cur\.unitId\)/);
  assert.match(source, /Η λίστα κλειδωμένων μελετών ανανεώθηκε/);
  assert.match(source, /function sanitizeHtmlFragment/);
  assert.match(source, /function sanitizeDocumentHtml/);
  assert.match(source, /function assertSafeExcelFile/);
  assert.match(source, /function assertSafeXlsxEnvelope/);
  assert.match(source, /p_import_token:importContext\.exportToken/);
  assert.match(source, /Οικονομική προσφορά \/ συμβατικές τιμές/);
  assert.match(source, /Συμβατική καθαρή αξία/);
  assert.match(source, /Math\.abs\(cov-c\)>0\.005/);
  assert.match(source, /p_pricing_mode:mode/);
  assert.doesNotMatch(source, /function isIntegerQuantityMaterial\(\)\{return true;\}/);
  assert.doesNotMatch(source, /const byId=\(arr,id\)=>\(arr\|\|\[\]\)\.find\(x=>x\.id===id\)/);
  assert.doesNotMatch(source, /SUPERVISOR_EMAILS/);
  assert.doesNotMatch(source, /genikigrammateas@rhodes\.gr|mkanakas@gmail\.com/i);
  assert.doesNotMatch(source, /\.rpc\(['"]import_catalog_request_atomic['"]/);
  assert.doesNotMatch(source, /xlsx@0\.18\.5|window\.XLSX|\bXLSX\./);
  assert.doesNotMatch(source, /document\.write\((?!sanitizeDocumentHtml)/);

  for (const rpc of resilientRpcs) {
    assert.match(source, new RegExp(`resilientRpc\\(['\"]${rpc}['\"]`), `λείπει η resilient RPC ${rpc}`);
  }
  for (const rpc of directRpcs) {
    assert.match(source, new RegExp(`rpc\\(['\"]${rpc}['\"]`), `λείπει η RPC ${rpc}`);
  }

  for (const table of criticalTables) {
    const directWrite = new RegExp(
      `from\\(['\"]${table}['\"]\\)(?:(?!;)[\\s\\S])*?\\.(?:insert|upsert|update|delete)\\(`,
      'g'
    );
    assert.doesNotMatch(source, directWrite, `βρέθηκε απευθείας εγγραφή στον ${table}`);
  }
  assert.doesNotMatch(source,/from\(['"]study_templates['"]\)(?:(?!;)[\s\S])*?\.(?:insert|upsert|update|delete)\(/g);
});

test('η πολιτική περιεχομένου καλύπτει κάθε inline script και οι τοπικές βιβλιοθήκες είναι καρφιτσωμένες με SRI', () => {
  const csp=source.match(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"/i)?.[1]||'';
  assert.match(csp,/script-src /);
  assert.match(csp,/script-src-attr 'none'/);
  assert.doesNotMatch(csp,/script-src[^;]*'unsafe-inline'/);
  const inlineScripts=[...source.matchAll(/<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi)].map(match=>match[1]);
  assert.equal(inlineScripts.length,2);
  for(const script of inlineScripts){
    const hash='sha256-'+crypto.createHash('sha256').update(script,'utf8').digest('base64');
    assert.ok(csp.includes(`'${hash}'`),`λείπει CSP hash για inline script: ${hash}`);
  }
  assert.match(csp,/script-src[^;]*'self'/);
  assert.match(csp,/script-src[^;]*file:/);
  assert.doesNotMatch(source,/cdn\.jsdelivr\.net/);
  const supabaseIntegrity=source.match(/src="vendor\/supabase\.js" integrity="(sha384-[A-Za-z0-9+/=]+)"/)?.[1];
  assert.ok(supabaseIntegrity);
  const supabaseBundle=fs.readFileSync(new URL('../vendor/supabase.js',import.meta.url));
  assert.equal(supabaseIntegrity,'sha384-'+crypto.createHash('sha384').update(supabaseBundle).digest('base64'));
  const excelIntegrity=source.match(/src="vendor\/exceljs\.min\.js" integrity="(sha384-[A-Za-z0-9+/=]+)"/)?.[1];
  assert.ok(excelIntegrity);
  const excelBundle=fs.readFileSync(new URL('../vendor/exceljs.min.js',import.meta.url));
  assert.equal(excelIntegrity,'sha384-'+crypto.createHash('sha384').update(excelBundle).digest('base64'));
});
