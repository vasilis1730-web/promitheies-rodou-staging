import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { JSDOM } from 'jsdom';
import ExcelJS from 'exceljs';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const html = source.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/gi, '');

function fixture() {
  return {
    profiles: [{
      id: 'viewer-1', email: 'viewer@example.test', full_name: 'Δοκιμαστικός χρήστης',
      role: 'viewer', municipal_unit_id: null
    }],
    user_app_permissions: [{ user_id: 'viewer-1', can_supervise: false }],
    municipal_units: [
      { id: 1, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΡΧΑΓΓΕΛΟΥ', short_name: 'ΑΡΧΑΓΓΕΛΟΥ', sort_order: 1 },
      { id: 2, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', short_name: 'ΑΤΑΒΥΡΟΥ', sort_order: 2 },
      { id: 3, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΦΑΝΤΟΥ', short_name: 'ΑΦΑΝΤΟΥ', sort_order: 3 },
      { id: 4, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΙΑΛΥΣΟΥ', short_name: 'ΙΑΛΥΣΟΥ', sort_order: 4 },
      { id: 5, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΛΛΙΘΕΑΣ', short_name: 'ΚΑΛΛΙΘΕΑΣ', sort_order: 5 },
      { id: 6, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΜΕΙΡΟΥ', short_name: 'ΚΑΜΕΙΡΟΥ', sort_order: 6 },
      { id: 7, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΛΙΝΔΙΩΝ', short_name: 'ΛΙΝΔΙΩΝ', sort_order: 7 },
      { id: 8, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', short_name: 'ΝΟΤΙΑΣ ΡΟΔΟΥ', sort_order: 8 },
      { id: 9, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΠΕΤΑΛΟΥΔΩΝ', short_name: 'ΠΕΤΑΛΟΥΔΩΝ', sort_order: 9 },
      { id: 10, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', short_name: 'ΡΟΔΟΥ', sort_order: 10 },
      { id: 11, name: 'ΔΗΜΟΣ ΡΟΔΟΥ', short_name: 'ΔΗΜΟΣ ΡΟΔΟΥ', sort_order: 11 }
    ],
    procurement_groups: [{
      id: 10, code: 'electrical', name: 'ΗΛΕΚΤΡΟΛΟΓΙΚΑ ΥΛΙΚΑ',
      short_name: 'Ηλεκτρολογικά', sort_order: 1, domain: 'procurement'
    }],
    materials: [{
      id: 'material-1', group_id: 10, code: 'EL-1', name: 'Υλικό δοκιμής',
      unit: 'τεμ.', quantity_scale: 0, default_unit_price: 10, sort_order: 1,
      is_active: true
    }],
    tender_overrides: [], unit_requests: [], request_lines: [], saved_versions: [],
    locked_studies: [], award_group_configurations: [], award_groups: [],
    award_group_memberships: []
  };
}

function queryBuilder(datasets, table, queryLog) {
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
      queryLog.push({ table, filters: state.filters.map(filter => [...filter]) });
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
  const datasets = fixture(), queryLog = [], errors = [];
  const dom = new JSDOM(html, {
    url: 'https://test.local/', runScripts: 'dangerously', pretendToBeVisual: true,
    beforeParse(window) {
      window.supabase = { createClient: () => ({
        auth: {
          getSession: async () => ({ data: { session: { user: { id: 'viewer-1' } } } }),
          signInWithPassword: async () => ({ error: null }), signOut: async () => ({ error: null }),
          updateUser: async () => ({ error: null })
        },
        from: table => queryBuilder(datasets, table, queryLog),
        rpc: async name => name === 'app_schema_version'
          ? { data: '36.6.1', error: null }
          : { data: null, error: null }
      }) };
      window.ExcelJS = ExcelJS;
      window.ResizeObserver = class { observe() {} disconnect() {} };
      window.confirm = () => true; window.prompt = () => null; window.open = () => null;
      window.addEventListener('error', event => errors.push(event.error?.message || event.message));
    }
  });
  const waitFor = async predicate => {
    const started = Date.now();
    while (!predicate()) {
      if (Date.now() - started > 3000) throw new Error('Timeout while opening test application');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
  };
  await waitFor(() => !dom.window.document.querySelector('#chooser').classList.contains('hidden'));
  return { dom, queryLog, errors, waitFor };
}

test('κενός κατάλογος Υπηρεσιών δεν στέλνει undefined group_id και καθαρίζει την προηγούμενη οθόνη', async () => {
  const { dom, queryLog, errors, waitFor } = await openApp();
  const { document } = dom.window;

  assert.match(document.querySelector('.chooser-sub').textContent, /μόνο σε προβολή/i);
  assert.equal(document.querySelectorAll('#awardGroupNav .award-group-chip').length, 4);
  assert.equal(document.querySelector('#awardGroupNav .award-group-chip[aria-current="true"]')?.dataset.awardGroupNo, '3');

  document.querySelector('#chooser [data-mode="procurement"]').click();
  await waitFor(() => document.querySelector('#tbody input.qin[disabled]'));
  assert.match(document.querySelector('#ptSub').textContent, /1/);
  const requestQueriesBefore = queryLog.filter(entry => entry.table === 'unit_requests').length;

  document.querySelector('#modeSwitch [data-mode="service"]').click();
  await waitFor(() => /Δεν έχει εισαχθεί κατάλογος υπηρεσιών/.test(document.querySelector('#ptTitle').textContent));

  assert.equal(document.querySelectorAll('#grpNav .pill').length, 0);
  assert.match(document.querySelector('#ptSub').textContent, /0 ομάδες · 0 εργασίες/);
  assert.match(document.querySelector('#tbody').textContent, /δεν περιέχει ακόμη πραγματικές ομοειδείς ομάδες υπηρεσιών/i);
  assert.doesNotMatch(document.querySelector('#toasts').textContent, /undefined|smallint/i);
  assert.equal(queryLog.filter(entry => entry.table === 'unit_requests').length, requestQueriesBefore);
  assert.equal(
    queryLog.some(entry => entry.filters.some(([, , value]) => value === undefined)),
    false,
    'δεν επιτρέπεται να φτάσει undefined τιμή σε φίλτρο της βάσης'
  );
  assert.deepEqual(errors, []);
  dom.window.close();
});
