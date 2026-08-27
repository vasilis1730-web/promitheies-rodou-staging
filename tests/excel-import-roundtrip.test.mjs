// Η εξαγωγή Excel της εφαρμογής πρέπει να μπορεί να ξαναδιαβαστεί από την ίδια την
// εφαρμογή. Δύο σφάλματα το εμπόδιζαν: (α) ο έλεγχος του «ΚΛΕΙΔΙΑ_ΕΙΔΩΝ» δεχόταν
// μόνο ακέραια material_id ενώ η βάση χρησιμοποιεί UUID, και (β) οι συγχωνευμένοι
// τίτλοι υποκατηγορίας επέστρεφαν το κείμενό τους σε όλες τις στήλες, οπότε έπεφταν
// στους ελέγχους του «Α/Α» και του «CE».
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ExcelJS from 'exceljs';
import { JSDOM } from 'jsdom';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const html = source.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/gi, '');

const GROUP_ID = '29';
const CONTEXT_KEY = '2026|10|29|SRV06|ΡΟΔΟΥ|Συντήρηση & αναγόμωση πυροσβεστήρων';
const MATERIAL_IDS = [
  'f9c24e9a-7c9c-4a9a-8fc1-03ba02ef4075',
  '18c6e8a9-d34b-436e-bf50-17ba7a3438cb',
];

function fnv1a(text) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) { h ^= text.charCodeAt(i); h = Math.imul(h, 16777619); }
  return ('00000000' + (h >>> 0).toString(16)).slice(-8).toUpperCase();
}

// Αναπαράγει τη μορφή που παράγει η buildStyledExcelExport, μαζί με τη
// συγχωνευμένη γραμμή υποκατηγορίας και τα veryHidden φύλλα ταυτότητας.
async function buildExport({ appVersion }) {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Συντήρηση πυροσβεστήρων');
  ws.columns = Array.from({ length: 12 }, () => ({ width: 12 }));
  ws.getRow(6).values = ['Α/Α', 'ΠΕΡΙΓΡΑΦΗ ΕΙΔΟΥΣ', 'ΜΟΝΑΔΑ ΜΕΤΡΗΣΗΣ', 'CPV', 'ΠΡΟΤΥΠΟ / ΕΤΕΠ',
    'ΤΙΜΗ ΜΟΝΑΔΑΣ\n(€, άνευ ΦΠΑ)', 'ΠΟΣΟΤΗΤΑ', 'ΔΑΠΑΝΗ\n(€, άνευ ΦΠΑ)', 'ΤΙΜΗ ΜΕ ΦΠΑ\n24% (€)',
    'ΤΕΧΝΙΚΕΣ ΠΡΟΔΙΑΓΡΑΦΕΣ', 'ΑΠΑΙΤΗΣΗ CE', 'ΠΑΡΑΤΗΡΗΣΕΙΣ ΤΕΥΧΟΥ'];

  ws.mergeCells(7, 1, 7, 12);
  ws.getCell(7, 1).value = 'Πυροσβεστήρες ξηράς κόνεως';

  [['Αναγόμωση πυροσβεστήρα ξηράς κόνεως 6 kg', 5.2, 33],
   ['Αναγόμωση πυροσβεστήρα ξηράς κόνεως 12 kg', 9, 300]].forEach(([name, price, qty], i) => {
    const r = 8 + i;
    ws.getRow(r).values = [i + 1, name, 'τεμ.', '24951230-6', 'ΕΛΟΤ ΕΝ 3-7',
      price, qty, null, null, 'Προδιαγραφή', 'ΟΧΙ', ''];
    ws.getCell(r, 8).value = { formula: `IF(OR(F${r}="",G${r}=""),"",F${r}*G${r})`, result: price * qty };
    ws.getCell(r, 9).value = { formula: `IF(F${r}="","",F${r}*(1+'ΣΗΜΕΙΩΣΕΙΣ'!$B$2))`, result: price * 1.24 };
  });

  const notes = wb.addWorksheet('ΣΗΜΕΙΩΣΕΙΣ');
  notes.getCell('A2').value = 'Συντελεστής ΦΠΑ:';
  notes.getCell('B2').value = 0.24;

  const meta = wb.addWorksheet('ΜΕΤΑΔΕΔΟΜΕΝΑ');
  meta.state = 'veryHidden';
  const expires = new Date(Date.now() + 7 * 864e5).toISOString();
  [['ΚΛΕΙΔΙ', 'ΤΙΜΗ'], ['SIGNATURE', 'RHODES_PROCUREMENT_EXPORT_V3'], ['APP_VERSION', appVersion],
   ['REQUEST_YEAR', '2026'], ['MUNICIPAL_UNIT_ID', '10'], ['MUNICIPAL_UNIT_NAME', 'ΡΟΔΟΥ'],
   ['GROUP_ID', GROUP_ID], ['GROUP_CODE', 'SRV06'], ['GROUP_NAME', 'Συντήρηση & αναγόμωση πυροσβεστήρων'],
   ['CONTEXT_KEY', CONTEXT_KEY], ['CHECKSUM', fnv1a(CONTEXT_KEY)],
   ['EXPORT_TOKEN', '84b0a99f-c76d-4ec9-9411-8e52cb5d5a71'], ['TOKEN_EXPIRES_AT', expires],
   ['CATALOG_COUNT', String(MATERIAL_IDS.length)], ['QUANTITY_SCOPE', 'ONLY_THIS_MUNICIPAL_UNIT'],
   ['CATALOG_SCOPE', 'ALL_UNITS_SAME_GROUP'], ['EXPORTED_AT', new Date().toISOString()],
  ].forEach((row, i) => { meta.getRow(i + 1).values = row; });

  const keys = wb.addWorksheet('ΚΛΕΙΔΙΑ_ΕΙΔΩΝ');
  keys.state = 'veryHidden';
  keys.getRow(1).values = ['Α/Α', 'MATERIAL_ID', 'MATERIAL_CODE', 'GROUP_ID', 'ΠΕΡΙΓΡΑΦΗ', 'ΜΟΝΑΔΑ'];
  MATERIAL_IDS.forEach((id, i) => {
    keys.getRow(i + 2).values = [i + 1, id, `SRV06-0${i + 1}`, Number(GROUP_ID), 'Είδος', 'τεμ.'];
  });

  return Buffer.from(await wb.xlsx.writeBuffer());
}

// Στήνει το ελάχιστο πραγματικό state που χρειάζεται η εφαρμογή για να τρέξει την
// εισαγωγή μέχρι το σημείο που θα χτυπούσε τη βάση.
function primeAppState(window) {
  window.ExcelJS = ExcelJS;
  window.confirm = () => true;
  window.alert = () => {};
  // Τα cur/GROUPS/MAT_BY_GROUP δηλώνονται με `let`, άρα δεν είναι ιδιότητες του
  // window: τα θέτουμε μέσα στο ίδιο λεξικό πεδίο με eval.
  window.eval(`
    cur = { unitId: '10', groupId: '${GROUP_ID}' };
    YEAR = 2026;
    GROUPS = [{ id: '${GROUP_ID}', code: 'SRV06', name: 'Συντήρηση & αναγόμωση πυροσβεστήρων',
                short_name: 'Συντήρηση πυροσβεστήρων', domain: 'service' }];
    UNITS = [{ id: '10', name: 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', short_name: 'ΡΟΔΟΥ' }];
    MAT_BY_GROUP = { '${GROUP_ID}': [
      { id: '${MATERIAL_IDS[0]}', name: 'Αναγόμωση πυροσβεστήρα ξηράς κόνεως 6 kg', short_name: 'Αναγόμωση πυροσβεστήρα ξηράς κόνεως 6 kg',
        unit: 'τεμ.', quantity_scale: 0, sort_order: 1, cpv: '', technical_specs: '', standards: '',
        ce_required: false, notes_for_tender: '', default_unit_price: 5.2 },
      { id: '${MATERIAL_IDS[1]}', name: 'Αναγόμωση πυροσβεστήρα ξηράς κόνεως 12 kg', short_name: 'Αναγόμωση πυροσβεστήρα ξηράς κόνεως 12 kg',
        unit: 'τεμ.', quantity_scale: 0, sort_order: 2, cpv: '', technical_specs: '', standards: '',
        ce_required: false, notes_for_tender: '', default_unit_price: 9 }
    ]};
    ME = { role: 'admin' };
    lines = {};
    hiddenMaterials = new Set();
  `);
}

function fileFrom(buffer) {
  const bytes = new Uint8Array(buffer);
  return {
    name: 'export.xlsx',
    size: bytes.byteLength,
    type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
  };
}

// Τρέχει την πραγματική importQuantitiesFromFile και επιστρέφει το μήνυμα σφάλματος.
// Χωρίς σύνδεση στη βάση η ροή φτάνει ως την εγγραφή, οπότε οτιδήποτε ΠΡΙΝ από αυτήν
// (ανάλυση γραμμών, έλεγχοι πεδίων) εμφανίζεται εδώ ως διαφορετικό μήνυμα.
async function runImport(buffer) {
  const dom = new JSDOM(html, { url: 'https://test.local/', runScripts: 'dangerously' });
  const { window } = dom;
  primeAppState(window);
  try {
    await window.importQuantitiesFromFile(fileFrom(buffer));
    return null;
  } catch (e) {
    return (e && e.message) || String(e);
  } finally {
    window.close();
  }
}

// Φορτώνει την εφαρμογή και εκθέτει readWorkbookRows πάνω σε ένα πραγματικό .xlsx.
async function readWithApp(buffer) {
  const dom = new JSDOM(html, { url: 'https://test.local/', runScripts: 'dangerously' });
  const { window } = dom;
  primeAppState(window);
  try {
    const imported = await window.readWorkbookRows(fileFrom(buffer));
    // Κρατάμε τον ανιχνευτή πριν κλείσει το παράθυρο, για να ελεγχθεί το ίδιο
    // αντίγραφο κώδικα που εκτέλεσε και την ανάγνωση.
    return { imported, isSectionBannerRow: window.isSectionBannerRow };
  } finally {
    window.close();
  }
}

const APP_VERSION = (source.match(/const APP_VERSION='([^']+)'/) || [])[1];

test('η εφαρμογή διαβάζει τη δική της εξαγωγή Excel', async () => {
  assert.ok(APP_VERSION, 'δεν εντοπίστηκε το APP_VERSION');
  const { imported } = await readWithApp(await buildExport({ appVersion: APP_VERSION }));

  // Τα UUID του καταλόγου γίνονται δεκτά ως material_id.
  assert.equal(imported.keyMap.size, MATERIAL_IDS.length);
  assert.equal(imported.keyMap.get(1), MATERIAL_IDS[0]);
  assert.equal(imported.keyMap.get(2), MATERIAL_IDS[1]);
  assert.equal(imported.metadata.GROUP_CODE, 'SRV06');
});

test('η συγχωνευμένη γραμμή υποκατηγορίας προσπερνιέται αντί να ακυρώνει την εισαγωγή', async () => {
  const buffer = await buildExport({ appVersion: APP_VERSION });
  const { imported, isSectionBannerRow } = await readWithApp(buffer);
  const headerIndex = imported.rows.findIndex(r => String(r[0] || '').trim() === 'Α/Α');
  assert.ok(headerIndex >= 0, 'δεν βρέθηκε η γραμμή επικεφαλίδων');

  // Το συγχωνευμένο κείμενο όντως επιστρέφεται σε όλες τις στήλες — αυτό ήταν το σφάλμα:
  // ο τίτλος κατέληγε στα πεδία «Α/Α» και «CE» της γραμμής 7.
  const banner = imported.rows[headerIndex + 1];
  assert.equal(String(banner[0]).trim(), 'Πυροσβεστήρες ξηράς κόνεως');
  assert.equal(String(banner[10]).trim(), 'Πυροσβεστήρες ξηράς κόνεως');
  assert.equal(isSectionBannerRow(banner), true);

  // Η πραγματική εισαγωγή πρέπει να προσπεράσει τη γραμμή και να φτάσει ως τη βάση.
  // Χωρίς τον έλεγχο, εδώ θα επέστρεφε «Μη έγκυρη τιμή CE στη γραμμή 7».
  const error = await runImport(buffer);
  assert.doesNotMatch(String(error), /τιμή CE/, 'ο τίτλος υποκατηγορίας διαβάστηκε ως δεδομένο είδους');
  assert.doesNotMatch(String(error), /γραμμή 7/, 'η γραμμή-τίτλος δεν προσπεράστηκε');
  assert.match(String(error), /βάση/, 'η ροή πρέπει να φτάνει ως το στάδιο εγγραφής στη βάση');
});

test('ο ανιχνευτής γραμμής-τίτλου δεν καταπίνει κανονικά είδη', () => {
  const dom = new JSDOM(html, { url: 'https://test.local/', runScripts: 'dangerously' });
  const { isSectionBannerRow } = dom.window;
  assert.equal(typeof isSectionBannerRow, 'function');

  assert.equal(isSectionBannerRow(Array(12).fill('Πυροσβεστήρες CO₂')), true);
  assert.equal(isSectionBannerRow([1, 'Αναγόμωση 6 kg', 'τεμ.', '24951230-6']), false);
  assert.equal(isSectionBannerRow(['', '', '']), false, 'κενή γραμμή δεν είναι τίτλος');
  assert.equal(isSectionBannerRow(['7', '7']), false, 'επαναλαμβανόμενος αριθμός δεν είναι τίτλος');
  assert.equal(isSectionBannerRow(['Μόνο ένα κελί']), false, 'ένα κελί δεν αρκεί');
  dom.window.close();
});
