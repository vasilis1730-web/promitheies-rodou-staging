import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { JSDOM } from 'jsdom';
import ExcelJS from 'exceljs';

const original = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const html = original.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/gi, '');

function fixture(configured) {
  const data = {
    profiles: [{ id: 'admin-1', email: 'admin@example.test', full_name: 'Διαχειριστής', role: 'admin', municipal_unit_id: null }],
    municipal_units: [
      { id: 1, name: 'Ρόδος', short_name: 'Ρόδου', sort_order: 1 },
      { id: 2, name: 'Ιαλυσός', short_name: 'Ιαλυσού', sort_order: 2 },
      { id: 3, name: 'Καλλιθέα', short_name: 'Καλλιθέας', sort_order: 3 },
      { id: 4, name: 'Αφάντου', short_name: 'Αφάντου', sort_order: 4 },
      { id: 5, name: 'Λίνδος', short_name: 'Λίνδου', sort_order: 5 },
      { id: 6, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', short_name: 'ΝΟΤΙΑΣ ΡΟΔΟΥ', sort_order: 6 },
      { id: 7, name: 'Αρχάγγελος', short_name: 'Αρχαγγέλου', sort_order: 7 },
      { id: 8, name: 'Πεταλούδες', short_name: 'Πεταλουδών', sort_order: 8 },
      { id: 9, name: 'Κάμειρος', short_name: 'Καμείρου', sort_order: 9 },
      { id: 10, name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', short_name: 'ΑΤΑΒΥΡΟΥ', sort_order: 10 },
      { id: 11, name: 'Δήμος Ρόδου', short_name: 'Σύνολο Δήμου', sort_order: 11 }
    ],
    procurement_groups: [{ id: 10, code: 'electrical', name: 'Ηλεκτρολογικό υλικό', short_name: 'Ηλεκτρολογικά', sort_order: 1, domain: 'procurement' }],
    materials: [
      { id: 1, group_id: 10, code: 'EL-1', name: 'Υλικό δοκιμής', unit: 'τεμ.', quantity_scale: 0, cpv: '31600000-2', default_unit_price: 1500, sort_order: 1, is_active: true },
      { id: 2, group_id: 10, code: 'EL-2', name: 'Καλώδιο δοκιμής', unit: 'm', quantity_scale: 3, cpv: '31300000-9', default_unit_price: 1000, sort_order: 2, is_active: true }
    ],
    tender_overrides: [], unit_requests: [], request_lines: [], saved_versions: [],
    locked_studies: [
      { id: 's1', municipal_unit_id: 2, group_id: 10, award_group_id: 102, request_year: 2026, seq: 1, net_total: 19000, item_count: 1, lines: [], locked_at: '2026-07-22T09:00:00Z' },
      { id: 's2', municipal_unit_id: 3, group_id: 10, award_group_id: 102, request_year: 2026, seq: 1, net_total: 10000, item_count: 1, lines: [], locked_at: '2026-07-23T09:00:00Z' }
    ]
  };
  data.award_group_configurations = configured ? [{
    id: 50, budget_year: 2026, decision_number: '123/2026', decision_date: '2026-07-21',
    decision_ada: 'ΨTEST', direct_award_cap: 30000, is_active: true, updated_at: '2026-07-21T00:00:00Z'
  }] : [];
  data.award_groups = configured ? [
    { id: 101, configuration_id: 50, group_no: 1, name: 'Ρόδου' },
    { id: 102, configuration_id: 50, group_no: 2, name: 'Ιαλυσού – Καλλιθέας – Αφάντου' },
    { id: 103, configuration_id: 50, group_no: 3, name: 'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου' },
    { id: 104, configuration_id: 50, group_no: 4, name: 'Πεταλουδών – Καμείρου – Ατταβύρου' }
  ] : [];
  data.award_group_memberships = configured ? [
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
  ] : [];
  return data;
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
      const result = { data: state.first ? (rows[0] || null) : rows, error: null };
      return Promise.resolve(result).then(resolve, reject);
    }
  };
  return api;
}

async function openApp(configured) {
  const datasets = fixture(configured);
  const errors = [];
  const rpcCalls = [];
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
        rpc: async (name,args) => {
          rpcCalls.push({name,args});
          if(name === 'app_schema_version')return {data:'36.6.5',error:null};
          if(name === 'secure_import_catalog_request_atomic')return {data:{request_id:'99',secure_import:true},error:null};
          if(name === 'issue_excel_export_token')return {data:{token:'11111111-1111-4111-8111-111111111111',expires_at:'2099-01-01T00:00:00Z'},error:null};
          return {data:1,error:null};
        }
      }) };
      window.ExcelJS = ExcelJS;
      window.ResizeObserver = class { observe() {} disconnect() {} };
      window.confirm = () => true; window.prompt = () => null;
      window.open = () => null;
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
  return { dom, errors, rpcCalls };
}

test('το όριο αθροίζεται σε όλα τα μέλη της ίδιας ομάδας Δ.Ε.', async () => {
  const { dom, errors } = await openApp(true);
  const { window } = dom;
  await window.selUnit(2);
  const state = JSON.parse(JSON.stringify(window.eval('({group:currentAwardGroup().name, committed:lockedNetSum(), count:CAP_LOCKED.length, localCount:LOCKED.length})')));
  assert.deepEqual(state, { group: 'Ιαλυσού – Καλλιθέας – Αφάντου', committed: 29000, count: 2, localCount: 1 });
  assert.match(window.document.querySelector('#capStrip').textContent, /Ιαλυσού – Καλλιθέας – Αφάντου/);
  assert.match(window.document.querySelector('#capStrip').textContent, /Μέρος Δ\.Ε\. Ιαλυσού\s*19\.000,00/);
  assert.match(window.document.querySelector('#capStrip').textContent, /29\.000,00/);

  const quantity = window.document.querySelector('input.qin');
  quantity.value = '1';
  quantity.dispatchEvent(new window.Event('input', { bubbles: true }));
  assert.match(window.eval('directAwardValidation(texosRows())'),/σύνολο της Ιαλυσού – Καλλιθέας – Αφάντου.*υπερβαίνει το κοινό όριο/i);
  window.document.querySelector('#btnLock').click();
  assert.equal(window.document.querySelector('#lockConfirm').disabled, true);
  assert.match(window.document.querySelector('#lockWarn').textContent, /υπέρβαση του ορίου/);

  window.document.querySelector('#btnHistory').click();
  assert.equal(window.document.querySelectorAll('#histBody tr').length, 2);
  assert.match(window.document.querySelector('#histBody').textContent, /Καλλιθέας/);
  assert.deepEqual(errors, []);
  dom.window.close();
});

test('χωρίς ενεργή απόφαση το κλείδωμα παραμένει απενεργοποιημένο', async () => {
  const { dom, errors } = await openApp(false);
  const text = dom.window.document.querySelector('#capStrip').textContent;
  assert.match(text, /κλείδωμα μελέτης είναι προσωρινά απενεργοποιημένο/i);
  assert.equal(dom.window.document.querySelector('#btnLock'), null);
  assert.deepEqual(errors, []);
  dom.window.close();
});

test('οι τέσσερις ομάδες και το όριο 30.000 € είναι ενσωματωμένα και αποθηκεύονται χωρίς χειροκίνητη κατανομή', async () => {
  const { dom, errors, rpcCalls } = await openApp(false);
  const { window } = dom;
  await window.openSettings();

  const groupInputs=[...window.document.querySelectorAll('#agGroupNames input[data-group-name]')];
  assert.equal(groupInputs.length,4);
  assert.ok(groupInputs.every(input=>input.readOnly));
  assert.deepEqual(groupInputs.map(input=>input.value),[
    'Ρόδου',
    'Ιαλυσού – Καλλιθέας – Αφάντου',
    'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',
    'Πεταλουδών – Καμείρου – Ατταβύρου'
  ]);
  assert.equal(window.document.querySelectorAll('#agMembershipRows tr').length,10);
  assert.equal(window.document.querySelector('#agMembershipRows select'),null);
  assert.equal(window.document.querySelector('#agDirectCap').readOnly,true);
  assert.equal(Number(window.document.querySelector('#agDirectCap').value),30000);
  assert.match(window.document.querySelector('#agMembershipRows').textContent,/ΑΤΑΒΥΡΟΥ[\s\S]*Ομάδα 4/);
  assert.match(window.document.querySelector('#agMembershipRows').textContent,/ΝΟΤΙΑΣ ΡΟΔΟΥ[\s\S]*Ομάδα 3/);
  assert.doesNotMatch(window.document.querySelector('#agMembershipRows').textContent,/Δεν αναγνωρίστηκε/);
  assert.equal(
    window.eval("canonicalAwardUnitCodeForUnit({name:'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ',short_name:'ΝΟΤΙΑΣ ΡΟΔΟΥ'})"),
    'south_rhodes'
  );
  assert.equal(
    window.eval("canonicalAwardGroupNoForUnit({name:'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ',short_name:'ΝΟΤΙΑΣ ΡΟΔΟΥ'})"),
    3
  );
  assert.equal(
    window.eval("canonicalAwardGroupNoForUnit({name:'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ',short_name:'ΡΟΔΟΥ'})"),
    1
  );
  assert.equal(
    window.eval("canonicalAwardUnitCodeForUnit({name:'Αττάβυρος',short_name:'Ατταβύρου'})"),
    'attavyros'
  );

  window.document.querySelector('#agDecisionNumber').value='321/2026';
  window.document.querySelector('#agDecisionDate').value='2026-08-05';
  window.document.querySelector('#agDecisionAda').value='ΨTEST';
  await window.saveAwardGroupSettings();
  const call=rpcCalls.find(item=>item.name==='save_award_group_configuration');
  assert.ok(call);
  assert.equal(call.args.p_direct_award_cap,30000);
  assert.deepEqual(JSON.parse(JSON.stringify(call.args.p_groups)),[
    {group_no:1,name:'Ρόδου',municipal_unit_ids:[1]},
    {group_no:2,name:'Ιαλυσού – Καλλιθέας – Αφάντου',municipal_unit_ids:[2,3,4]},
    {group_no:3,name:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',municipal_unit_ids:[5,6,7]},
    {group_no:4,name:'Πεταλουδών – Καμείρου – Ατταβύρου',municipal_unit_ids:[8,9,10]}
  ]);
  assert.deepEqual(errors,[]);
  dom.window.close();
});

test('η ποσότητα 0,4 m διατηρείται ως δεκαδική και δεν μετατρέπεται σε ακέραιο', async () => {
  const { dom, errors } = await openApp(true);
  const { window } = dom;
  const metreInput = [...window.document.querySelectorAll('input.qin')].find(x => x.dataset.mid === '2');
  assert.ok(metreInput);
  metreInput.value = '0.4';
  metreInput.dispatchEvent(new window.Event('input', { bubbles: true }));
  metreInput.dispatchEvent(new window.Event('blur', { bubbles: true }));
  const result = JSON.parse(JSON.stringify(window.eval(`({stored:lines[2].q,payload:requestLinesPayload().find(x=>x.material_id==='2').quantity})`)));
  assert.deepEqual(result, { stored: 0.4, payload: 0.4 });
  assert.deepEqual(errors, []);
  dom.window.close();
});

async function excelFileFor(window,{formulaInDescription=false,extraSheet=false,hyperlink=false}={}) {
  const metadata = JSON.parse(JSON.stringify(window.eval(`(()=>{
    const ctx=currentExcelContext();
    ctx.exportToken='11111111-1111-4111-8111-111111111111';
    ctx.tokenExpiresAt='2099-01-01T00:00:00Z';
    return metadataRows(ctx,2);
  })()`)));
  const data = [
    ['Α/Α','Περιγραφή είδους','Μονάδα μέτρησης','CPV','Τιμή μονάδας','Ποσότητα','Τεχνικές προδιαγραφές'],
    [1,'Υλικό δοκιμής','τεμ.','31600000-2',1500,1,''],
    [2,'Καλώδιο δοκιμής','m','31300000-9',1000,0.4,'']
  ];
  const keys = [
    ['Α/Α','MATERIAL_ID','MATERIAL_CODE','GROUP_ID','ΠΕΡΙΓΡΑΦΗ','ΜΟΝΑΔΑ'],
    [1,'1','EL-1','10','Υλικό δοκιμής','τεμ.'],
    [2,'2','EL-2','10','Καλώδιο δοκιμής','m']
  ];
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Υλικά και ποσότητες');
  data.forEach(row=>ws.addRow(row));
  if(formulaInDescription)ws.getCell('B2').value={formula:'1+1',result:2};
  if(hyperlink)ws.getCell('B2').value={text:'Κακόβουλος σύνδεσμος',hyperlink:'javascript:alert(1)'};
  const meta=wb.addWorksheet('ΜΕΤΑΔΕΔΟΜΕΝΑ');metadata.forEach(row=>meta.addRow(row));meta.state='veryHidden';
  const keySheet=wb.addWorksheet('ΚΛΕΙΔΙΑ_ΕΙΔΩΝ');keys.forEach(row=>keySheet.addRow(row));keySheet.state='veryHidden';
  if(extraSheet)wb.addWorksheet('ΚΡΥΦΟ').addRow(['ξένο']);
  const binary=await wb.xlsx.writeBuffer();
  const bytes=binary instanceof Uint8Array?binary:new Uint8Array(binary);
  const exact=bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength);
  return {
    name:'ΕΛΕΓΧΟΜΕΝΗ_ΕΞΑΓΩΓΗ.xlsx',
    type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    size:bytes.byteLength,
    arrayBuffer:async()=>exact
  };
}

test('οι τιμές από βάση και μηνύματα αποδίδονται ως κείμενο χωρίς XSS', async () => {
  const {dom,errors}=await openApp(true);
  const {window}=dom;
  const payload='<img src=x onerror="window.__xss=1"><svg onload="window.__xss=2"></svg>';
  window.eval(`(()=>{
    UNITS[0].short_name=${JSON.stringify(payload)};
    GROUPS[0].short_name=${JSON.stringify(payload)};
    MAT_BY_GROUP[10][0].name=${JSON.stringify(payload)};
    MAT_BY_GROUP[10][0].unit=${JSON.stringify(payload)};
    buildDENav();buildGrpNav();syncNav();render();toast(${JSON.stringify(payload)},'err');
  })()`);
  assert.equal(window.__xss,undefined);
  assert.equal(window.document.querySelector('img,iframe,[onerror],[onload]'),null);
  assert.match(window.document.body.textContent,/<img src=x onerror=/);

  const dirty='<!doctype html><html><head><title>x</title></head><body><img src=x onerror="alert(1)"><a href="javascript:alert(1)" target="_blank">x</a><script>alert(1)</script><p style="background:url(javascript:alert(1))">ok</p></body></html>';
  const clean=window.eval(`sanitizeDocumentHtml(${JSON.stringify(dirty)})`);
  const preview=new JSDOM(clean);
  assert.equal(preview.window.document.querySelector('img,script,iframe,[onerror]'),null);
  assert.equal(preview.window.document.querySelector('a').hasAttribute('href'),false);
  assert.equal(preview.window.document.querySelector('p').hasAttribute('style'),false);
  preview.window.close();
  assert.deepEqual(errors,[]);
  dom.window.close();
});

test('έγκυρο Excel χρησιμοποιεί το νέο ατομικό RPC και δελτίο προέλευσης', async () => {
  const {dom,errors,rpcCalls}=await openApp(true);
  const file=await excelFileFor(dom.window);
  await dom.window.eval('importQuantitiesFromFile')(file);
  const call=rpcCalls.find(x=>x.name==='secure_import_catalog_request_atomic');
  assert.ok(call,'δεν κλήθηκε η ασφαλής εισαγωγή');
  assert.equal(call.args.p_import_token,'11111111-1111-4111-8111-111111111111');
  assert.equal(call.args.p_lines.find(x=>String(x.material_id)==='2').quantity,0.4);
  assert.equal(rpcCalls.some(x=>x.name==='import_catalog_request_atomic'),false);
  assert.deepEqual(errors,[]);
  dom.window.close();
});

test('Excel με τύπο σε εισαγόμενο πεδίο, ξένο φύλλο ή υπερβολικό μέγεθος απορρίπτεται', async () => {
  const {dom}=await openApp(true);
  await assert.rejects(dom.window.eval('importQuantitiesFromFile')(await excelFileFor(dom.window,{formulaInDescription:true})),/Δεν επιτρέπεται τύπος/);
  await assert.rejects(dom.window.eval('readWorkbookRows')(await excelFileFor(dom.window,{extraSheet:true})),/ένα και μοναδικό φύλλο|μόνο το φύλλο δεδομένων/);
  await assert.rejects(dom.window.eval('readWorkbookRows')(await excelFileFor(dom.window,{hyperlink:true})),/υπερσύνδεσμο/);
  const oversized={name:'μεγάλο.xlsx',type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',size:8*1024*1024+1,arrayBuffer:async()=>{throw new Error('δεν πρέπει να διαβαστεί');}};
  await assert.rejects(dom.window.eval('readWorkbookRows')(oversized),/8 MB/);
  dom.window.close();
});
