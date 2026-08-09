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
      { id: 1, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', short_name: 'ΡΟΔΟΥ', sort_order: 1 },
      { id: 11, name: 'ΔΗΜΟΣ ΡΟΔΟΥ', short_name: 'ΣΥΝΟΛΟ ΔΗΜΟΥ', sort_order: 11 }
    ],
    procurement_groups: [
      { id: 10, code: 'electrical', name: 'Ηλεκτρολογικό υλικό', short_name: 'Ηλεκτρολογικά', sort_order: 1, domain: 'procurement' },
      { id: 20, code: 'cleaning-service', name: 'Καθαρισμός δημοτικών χώρων', short_name: 'Καθαρισμοί', sort_order: 2, domain: 'service' }
    ],
    materials: [
      { id: 1, group_id: 10, name: 'Υλικό δοκιμής', unit: 'τεμ.', quantity_scale: 0, default_unit_price: 10, sort_order: 1, is_active: true },
      { id: 2, group_id: 20, name: 'Εργασία δοκιμής', unit: 'ώρα', quantity_scale: 3, default_unit_price: 20, sort_order: 1, is_active: true }
    ],
    award_group_configurations: [{ id: 50, budget_year: 2026, decision_number: '1/2026', decision_date: '2026-08-01', decision_ada: 'ΨTEST', direct_award_cap: 30000, is_active: true }],
    award_groups: [{ id: 101, configuration_id: 50, group_no: 1, name: 'Ρόδου' }],
    award_group_memberships: [{ configuration_id: 50, award_group_id: 101, municipal_unit_id: 1 }],
    tender_overrides: [], unit_requests: [], request_lines: [], saved_versions: [], locked_studies: [],
    mo_suppliers: [], mo_receivers: [], mo_orders: [], mo_contracts: [], mo_contract_items: [], mo_order_items: []
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
      if (table === 'mo_orders' && datasets.__moOrdersReadError) {
        return Promise.resolve({
          data: null,
          error: { message: 'column mo_orders.study_id does not exist' }
        }).then(resolve, reject);
      }
      let rows = (datasets[table] || []).map(row => ({ ...row }));
      rows = rows.filter(row => state.filters.every(([kind, key, value]) => {
        if (kind === 'eq') return String(row[key]) === String(value);
        if (kind === 'lt') return Number(row[key]) < Number(value);
        if (kind === 'in') return value.map(String).includes(String(row[key]));
        return true;
      }));
      if (table === 'locked_studies') {
        rows = rows.map(row => ({
          ...row,
          municipal_units: datasets.municipal_units.find(unit => String(unit.id) === String(row.municipal_unit_id)) || null,
          procurement_groups: datasets.procurement_groups.find(group => String(group.id) === String(row.group_id)) || null
        }));
      }
      if (state.range) rows = rows.slice(state.range[0], state.range[1] + 1);
      if (state.limit !== null) rows = rows.slice(0, state.limit);
      return Promise.resolve({ data: state.first ? (rows[0] || null) : rows, error: null }).then(resolve, reject);
    }
  };
  return api;
}

async function openApp() {
  const datasets = fixture(), errors = [];
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
      window.confirm = () => true; window.prompt = () => null; window.open = () => null;
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
  return { dom, datasets, errors, waitFor };
}

test('η ενότητα Δελτία επαναφορτώνει τη μονάδα και εμφανίζει μελέτη που κλειδώθηκε μετά την προηγούμενη επίσκεψη', async () => {
  const { dom, datasets, errors, waitFor } = await openApp();
  const { window } = dom;

  window.document.querySelector('#chooser [data-mode="orders"]').click();
  await waitFor(() => window.document.querySelector('#ordersView .mo-pill'));
  window.document.querySelector('#ordersView .mo-pill').click();
  await waitFor(() => /Καμία κλειδωμένη μελέτη/.test(window.document.querySelector('#ordersView').textContent));

  datasets.locked_studies.push({
    id: 'study-service-1', municipal_unit_id: 1, group_id: 20, request_year: 2026,
    seq: 1, label: 'ΔΟΚΙΜΗ STAGING ΥΠΗΡΕΣΙΩΝ', net_total: 1200, item_count: 1,
    supplier_name: null, kimdis_url: null, lines: [], locked_at: '2026-08-06T10:00:00Z',
    record_status: 'active'
  });

  await window.switchMode('service');
  await waitFor(() => window.document.querySelector('input.qin[data-mid="2"]'));
  await window.switchMode('orders');
  await waitFor(() => /ΔΟΚΙΜΗ STAGING ΥΠΗΡΕΣΙΩΝ/.test(window.document.querySelector('#ordersView').textContent));

  assert.match(window.document.querySelector('#ordersView').textContent, /ΔΟΚΙΜΗ STAGING ΥΠΗΡΕΣΙΩΝ/);
  assert.match(window.document.querySelector('#ordersView').textContent, /ΥΠΗΡΕΣΙΕΣ/);
  assert.deepEqual(errors, []);
  dom.window.close();
});

test('σφάλμα ανάγνωσης δελτίων δεν κρύβει ξανά τις κλειδωμένες μελέτες', async () => {
  const { dom, datasets, waitFor } = await openApp();
  const { window } = dom;

  datasets.locked_studies.push({
    id: 'study-service-visible', municipal_unit_id: 1, group_id: 20, request_year: 2026,
    seq: 1, label: 'ΜΕΛΕΤΗ ΠΟΥ ΠΡΕΠΕΙ ΝΑ ΦΑΙΝΕΤΑΙ', net_total: 1200, item_count: 1,
    supplier_name: null, kimdis_url: null, lines: [], locked_at: '2026-08-06T10:00:00Z',
    record_status: 'active'
  });
  datasets.__moOrdersReadError = true;

  window.document.querySelector('#chooser [data-mode="orders"]').click();
  await waitFor(() => /ΜΕΛΕΤΗ ΠΟΥ ΠΡΕΠΕΙ ΝΑ ΦΑΙΝΕΤΑΙ/.test(window.document.querySelector('#ordersView').textContent));

  assert.match(window.document.querySelector('#ordersView').textContent, /ΜΕΛΕΤΗ ΠΟΥ ΠΡΕΠΕΙ ΝΑ ΦΑΙΝΕΤΑΙ/);
  assert.doesNotMatch(window.document.querySelector('#ordersView').textContent, /Καμία κλειδωμένη μελέτη/);
  dom.window.close();
});
