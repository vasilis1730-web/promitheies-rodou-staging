import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { JSDOM } from 'jsdom';
import ExcelJS from 'exceljs';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const html = source.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/gi, '');

function fixture() {
  return {
    profiles: [{ id: 'admin-1', email: 'admin@example.test', full_name: 'Διαχειριστής', role: 'admin', municipal_unit_id: null }],
    user_app_permissions: [{ user_id: 'admin-1', can_supervise: true }],
    municipal_units: [
      { id: 1, name: 'Ρόδος', short_name: 'Ρόδου', sort_order: 1 },
      { id: 2, name: 'Ιαλυσός', short_name: 'Ιαλυσού', sort_order: 2 },
      { id: 3, name: 'Καλλιθέα', short_name: 'Καλλιθέας', sort_order: 3 },
      { id: 4, name: 'Αφάντου', short_name: 'Αφάντου', sort_order: 4 },
      { id: 5, name: 'Λίνδος', short_name: 'Λίνδου', sort_order: 5 },
      { id: 6, name: 'Νότια Ρόδος', short_name: 'Νότιας Ρόδου', sort_order: 6 },
      { id: 7, name: 'Αρχάγγελος', short_name: 'Αρχαγγέλου', sort_order: 7 },
      { id: 8, name: 'Πεταλούδες', short_name: 'Πεταλουδών', sort_order: 8 },
      { id: 9, name: 'Κάμειρος', short_name: 'Καμείρου', sort_order: 9 },
      { id: 10, name: 'Αττάβυρος', short_name: 'Ατταβύρου', sort_order: 10 },
      { id: 11, name: 'Δήμος Ρόδου', short_name: 'Σύνολο Δήμου', sort_order: 11 }
    ],
    procurement_groups: [
      { id: 10, code: 'electrical', name: 'Ηλεκτρολογικό υλικό', short_name: 'Ηλεκτρολογικά', sort_order: 1, domain: 'procurement' },
      { id: 20, code: 'cleaning-service', name: 'Καθαρισμός δημοτικών χώρων', short_name: 'Καθαρισμοί', sort_order: 2, domain: 'service' }
    ],
    materials: [
      { id: 1, group_id: 10, code: 'EL-1', name: 'Ηλεκτρικός πίνακας', unit: 'τεμ.', quantity_scale: 0, cpv: '31214500-4', default_unit_price: 1000, subcategory: 'Πίνακες', technical_specs: 'Με μεταλλικό περίβλημα.', standards: 'EN 61439', ce_required: true, sort_order: 1, is_active: true },
      { id: 2, group_id: 20, code: 'SV-1', name: 'Καθαρισμός κοινόχρηστου χώρου', unit: 'ώρα', quantity_scale: 3, cpv: '90910000-9', default_unit_price: 50, subcategory: 'Καθαρισμοί', technical_specs: 'Με καταγραφή θέσης και χρόνου εργασίας.', standards: 'Σχέδιο ασφάλειας υπηρεσίας', ce_required: false, sort_order: 1, is_active: true }
    ],
    tender_overrides: [], unit_requests: [], request_lines: [], saved_versions: [], locked_studies: [],
    award_group_configurations: [{ id: 50, budget_year: 2026, decision_number: '123/2026', decision_date: '2026-07-21', decision_ada: 'ΨTEST', direct_award_cap: 30000, is_active: true, updated_at: '2026-07-21T00:00:00Z' }],
    award_groups: [
      { id: 101, configuration_id: 50, group_no: 1, name: 'Ρόδου' },
      { id: 102, configuration_id: 50, group_no: 2, name: 'Ιαλυσού – Καλλιθέας – Αφάντου' },
      { id: 103, configuration_id: 50, group_no: 3, name: 'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου' },
      { id: 104, configuration_id: 50, group_no: 4, name: 'Πεταλουδών – Καμείρου – Ατταβύρου' }
    ],
    award_group_memberships: [
      { configuration_id: 50, award_group_id: 101, municipal_unit_id: 1 },
      { configuration_id: 50, award_group_id: 102, municipal_unit_id: 2 },
      { configuration_id: 50, award_group_id: 102, municipal_unit_id: 3 },
      { configuration_id: 50, award_group_id: 102, municipal_unit_id: 4 },
      { configuration_id: 50, award_group_id: 103, municipal_unit_id: 5 },
      { configuration_id: 50, award_group_id: 103, municipal_unit_id: 6 },
      { configuration_id: 50, award_group_id: 103, municipal_unit_id: 7 },
      { configuration_id: 50, award_group_id: 104, municipal_unit_id: 8 },
      { configuration_id: 50, award_group_id: 104, municipal_unit_id: 9 },
      { configuration_id: 50, award_group_id: 104, municipal_unit_id: 10 }
    ]
  };
}

function queryBuilder(datasets, table) {
  const state = { filters: [], first: false, limit: null, range: null };
  const api = {
    select() { return api; },
    eq(key, value) { state.filters.push(['eq', key, value]); return api; },
    lt(key, value) { state.filters.push(['lt', key, value]); return api; },
    in(key, value) { state.filters.push(['in', key, value]); return api; },
    order() { return api; },
    limit(value) { state.limit = value; return api; },
    range(from, to) { state.range = [from, to]; return api; },
    single() { state.first = true; return api; },
    maybeSingle() { state.first = true; return api; },
    insert() { return api; }, upsert() { return api; }, update() { return api; }, delete() { return api; },
    then(resolve, reject) {
      let rows = (datasets[table] || []).map(row => ({ ...row }));
      rows = rows.filter(row => state.filters.every(([kind, key, value]) => {
        if (kind === 'eq') return String(row[key]) === String(value);
        if (kind === 'lt') return Number(row[key]) < Number(value);
        if (kind === 'in') return value.map(String).includes(String(row[key]));
        return true;
      }));
      if (state.range) rows = rows.slice(state.range[0], state.range[1] + 1);
      if (state.limit !== null) rows = rows.slice(0, state.limit);
      return Promise.resolve({ data: state.first ? (rows[0] || null) : rows, error: null }).then(resolve, reject);
    }
  };
  return api;
}

async function openApp() {
  const datasets = fixture(), popups = [], errors = [];
  const dom = new JSDOM(html, {
    url: 'https://test.local/', runScripts: 'dangerously', pretendToBeVisual: true,
    beforeParse(window) {
      window.supabase = { createClient: () => ({
        auth: {
          getSession: async () => ({ data: { session: { user: { id: 'admin-1' } } } }),
          signInWithPassword: async () => ({ error: null }), signOut: async () => ({ error: null }),
          updateUser: async () => ({ error: null })
        },
        from: table => queryBuilder(datasets, table),
        rpc: async name => name === 'app_schema_version' ? { data: '36.6.5', error: null } : { data: 1, error: null }
      }) };
      window.ExcelJS = ExcelJS;
      window.ResizeObserver = class { observe() {} disconnect() {} };
      window.confirm = () => true; window.prompt = () => null;
      window.open = () => {
        const popup = new JSDOM('<!doctype html><html><head></head><body></body></html>', { url: 'https://document.test/', pretendToBeVisual: true });
        popup.window.focus = () => {}; popup.window.print = () => {};
        popups.push(popup);
        return popup.window;
      };
      window.addEventListener('error', event => errors.push(event.error?.message || event.message));
    }
  });
  const waitFor = async predicate => {
    const start = Date.now();
    while (!predicate()) {
      if (Date.now() - start > 3000) throw new Error('Timeout while opening test application');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  };
  await waitFor(() => !dom.window.document.querySelector('#chooser').classList.contains('hidden'));
  dom.window.document.querySelector('#chooser [data-mode="procurement"]').click();
  await waitFor(() => dom.window.document.querySelector('input.qin'));
  return { dom, popups, errors, waitFor };
}

function generatedText(window, popups, fn) {
  const before = popups.length;
  window.eval(fn + '()');
  assert.equal(popups.length, before + 1, `${fn} δεν άνοιξε έγγραφο`);
  return popups.at(-1).window.document.body.textContent.replace(/\s+/g, ' ').trim();
}

test('τα πρότυπα και οι προσαρμογές είναι χωριστά ανά τύπο σύμβασης', () => {
  assert.doesNotMatch(source, /function\s+svcRewrite(?:Doc)?\s*\(/);
  assert.match(source, /function generateServiceStudy\s*\(/);
  assert.match(source, /function generateServiceSpecsDoc\s*\(/);
  assert.match(source, /function generateServiceDirectAwardInvitation\s*\(/);
  assert.match(source, /return domain\+'\:_COMMON'/);
  assert.match(source, /domain\+'\:'\+g\.code/);
});

test('τα παραγόμενα τεύχη Προμήθειας και Υπηρεσίας δεν ανταλλάσσουν ορολογία ή άρθρα εκτέλεσης', async () => {
  const { dom, popups, errors, waitFor } = await openApp();
  const { window } = dom;

  window.eval('lines={1:{q:3}}');
  const procurement = [
    generatedText(window, popups, 'generateStudy'),
    generatedText(window, popups, 'generateSpecsDoc'),
    generatedText(window, popups, 'generateDirectAwardInvitation')
  ].join(' ');
  assert.match(procurement, /ΜΕΛΕΤΗ ΠΡΟΜΗΘΕΙΑΣ/);
  assert.match(procurement, /άρθρο 206/i);
  assert.match(procurement, /άρθρο 208/i);
  assert.match(procurement, /άρθρο 213/i);
  assert.match(procurement, /πέντε \(5\) ημέρες/i);
  assert.match(procurement, /βεβαίωση του προϊσταμένου της υπηρεσίας/i);
  assert.match(procurement, /προορίζονται τα αγαθά/i);
  assert.doesNotMatch(procurement, /προορίζ(?:εται η υπηρεσία|ονται οι υπηρεσίες)/i);
  assert.doesNotMatch(procurement, /παρακολούθηση και εντολές \(άρθρο 216\)/i);

  await window.eval("switchMode('service')");
  await waitFor(() => window.document.querySelector('input.qin[data-mid="2"]'));
  window.eval('lines={2:{q:60}}');
  const service = [
    generatedText(window, popups, 'generateStudy'),
    generatedText(window, popups, 'generateSpecsDoc'),
    generatedText(window, popups, 'generateDirectAwardInvitation')
  ].join(' ');
  assert.match(service, /ΜΕΛΕΤΗ ΠΑΡΟΧΗΣ ΥΠΗΡΕΣΙΩΝ/);
  assert.match(service, /άρθρο 216/i);
  assert.match(service, /άρθρο 219/i);
  assert.match(service, /πέντε \(5\) ημέρες/i);
  assert.match(service, /βεβαίωση του προϊσταμένου της υπηρεσίας/i);
  assert.match(service, /προορίζ(?:εται η υπηρεσία|ονται οι υπηρεσίες)/i);
  assert.doesNotMatch(service, /προορίζονται τα αγαθά/i);
  assert.doesNotMatch(service, /προμηθευτής/i);
  assert.doesNotMatch(service, /δελτίο αποστολής/i);
  assert.doesNotMatch(service, /σήμανση CE/i);
  assert.doesNotMatch(service, /παράδοση υλικών/i);

  assert.equal(window.eval("tenderGroupOverrideKey({code:'same'},'procurement')"), 'procurement:same');
  assert.equal(window.eval("tenderGroupOverrideKey({code:'same'},'service')"), 'service:same');
  assert.deepEqual(errors, []);
  popups.forEach(p => p.window.close());
  dom.window.close();
});

test('η πρόσκληση απευθείας ανάθεσης απορρίπτει ελλιπείς τιμές και υπέρβαση ορίου', async () => {
  const { dom, popups } = await openApp();
  const { window } = dom;
  const missing = window.eval("directAwardValidation([{q:1,p:null}])");
  const over = window.eval("directAwardValidation([{q:1,p:30000.01}])");
  const valid = window.eval("directAwardValidation([{q:1,p:30000}])");
  assert.match(missing, /τιμή μονάδας/i);
  assert.match(over, /30\.000/);
  assert.equal(valid, '');
  assert.equal(popups.length, 0);
  dom.window.close();
});
