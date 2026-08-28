import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const edgeFn = fs.readFileSync(new URL('../supabase/functions/kimdis-lookup/index.ts', import.meta.url), 'utf8');

/* Οι κανόνες εξάγονται από το ίδιο το index.html: αν αλλάξουν εκεί χωρίς να
   αλλάξουν οι δοκιμές, το CI αποτυγχάνει. */
const sandbox = vm.createContext({});
for (const [name, pattern] of [
  ['KIMDIS_ADAM_RE', /const KIMDIS_ADAM_RE=[^\n]+/],
  ['kimdisAfm', /const kimdisAfm=[^\n]+/],
  ['kimdisMapContract', /function kimdisMapContract\(raw\)\{[\s\S]*?\n\}/],
  ['kimdisDiscountPct', /function kimdisDiscountPct\(net,estimated\)\{[\s\S]*?\n\}/]
]) {
  const code = source.match(pattern)?.[0];
  assert.ok(code, `δεν βρέθηκε ο κανόνας ${name} στο index.html`);
  vm.runInContext(code, sandbox);
}
// Τα const δηλώνονται στο lexical scope του context και δεν γίνονται ιδιότητες
// του sandbox — διαβάζονται με αποτίμηση του ονόματος μέσα στο context.
const read = name => vm.runInContext(name, sandbox);
const kimdisMapContract = read('kimdisMapContract');
const kimdisDiscountPct = read('kimdisDiscountPct');
const kimdisAfm = read('kimdisAfm');
const KIMDIS_ADAM_RE = read('KIMDIS_ADAM_RE');

/* Απάντηση στο ΑΚΡΙΒΕΣ σχήμα του ΚΗΜΔΗΣ Open Data API. */
const SYMV = {
  title: 'ΣΥΝΤΗΡΗΣΗ ΚΑΙ ΑΝΑΓΟΜΩΣΗ ΠΥΡΟΣΒΕΣΤΗΡΩΝ Δ.Ε. ΡΟΔΟΥ',
  referenceNumber: '25SYMV017115178',
  contractNumber: '2/16988',
  contractSignedDate: '2026-03-11',
  submissionDate: '2026-03-11T10:00:00.000',
  aaht: '206123',
  organization: { key: '6265', value: 'ΔΗΜΟΣ ΡΟΔΟΥ' },
  legalContext: { key: '2', value: 'ν.4412/2016 - Βιβλίο Ι – κάτω των ορίων' },
  contractingDataDetails: {
    signers: { key: '1', value: 'ΔΗΜΑΡΧΟΣ ΡΟΔΟΥ' },
    contractingMembersDataList: [
      { country: { key: 'GR', value: 'Ελλάδα' }, vatNumber: '099123456', greekVatNumber: true, name: 'ΖΑΙΡΗΣ ΑΕ' }
    ]
  },
  totalCostWithVAT: 4968.00,
  totalCostWithoutVAT: 4006.45,
  objectDetailsList: [{ quantity: 1, costWithoutVAT: 4006.45, vat: '24',
    cpvs: [{ key: '50413200-5', value: 'Υπηρεσίες επισκευής και συντήρησης εξοπλισμού πυρόσβεσης' }] }],
  noticeReferenceNumber: '25PROC014500000'
};

test('χαρτογραφεί τα πεδία της σύμβασης στα πεδία της φόρμας', () => {
  const k = kimdisMapContract(SYMV);
  assert.equal(k.adam, '25SYMV017115178');
  assert.equal(k.protocol_no, '2/16988');
  assert.equal(k.signed_date, '2026-03-11', 'η ημερομηνία κόβεται σε μορφή που δέχεται το input[type=date]');
  assert.equal(k.supplier_name, 'ΖΑΙΡΗΣ ΑΕ');
  assert.equal(k.supplier_afm, '099123456');
  assert.equal(k.net_total, 4006.45, 'χρησιμοποιείται η ΚΑΘΑΡΗ αξία, όχι η αξία με ΦΠΑ');
  assert.equal(k.gross_total, 4968.00);
  assert.equal(k.vat_rate, 24);
  assert.equal(k.aaht, '206123');
  assert.equal(k.organization, 'ΔΗΜΟΣ ΡΟΔΟΥ');
});

test('η ημερομηνία με ώρα κόβεται σωστά', () => {
  assert.equal(kimdisMapContract({ contractSignedDate: '2026-03-11T10:00:00.000' }).signed_date, '2026-03-11');
});

test('αντέχει ελλιπή ή κενή απάντηση χωρίς να σκάσει', () => {
  for (const raw of [null, undefined, {}, { contractingDataDetails: {} }, { objectDetailsList: [] }]) {
    const k = kimdisMapContract(raw);
    assert.equal(k.adam, null);
    assert.equal(k.supplier_afm, null);
    assert.equal(k.net_total, null);
    assert.equal(k.vat_rate, null);
  }
});

test('απορρίπτει μη αριθμητικές ή εκτός ορίων τιμές', () => {
  assert.equal(kimdisMapContract({ totalCostWithoutVAT: 'άκυρο' }).net_total, null);
  assert.equal(kimdisMapContract({ objectDetailsList: [{ vat: '150' }] }).vat_rate, null, 'ΦΠΑ 150% δεν γίνεται δεκτός');
  assert.equal(kimdisMapContract({ objectDetailsList: [{ vat: '0' }] }).vat_rate, 0, 'μηδενικός ΦΠΑ είναι έγκυρος');
});

test('το ΑΦΜ καθαρίζεται από μη ψηφία ώστε να ταιριάζει με το μητρώο', () => {
  assert.equal(kimdisAfm('EL 099123456'), '099123456');
  assert.equal(kimdisAfm('099-123-456'), '099123456');
  assert.equal(kimdisAfm(null), '');
});

test('υπολογίζει την έκπτωση από την καθαρή αξία', () => {
  assert.equal(kimdisDiscountPct(4006.45, 4781.16), 16.2034);
  assert.equal(kimdisDiscountPct(4781.16, 4781.16), 0, 'ίδιο ποσό σημαίνει μηδενική έκπτωση');
  assert.equal(kimdisDiscountPct(0, 4781.16), 100);
});

test('πάνω από την εκτιμώμενη αξία δεν εφαρμόζεται τίποτα', () => {
  // Η βάση απαγορεύει σύμβαση μεγαλύτερη της μελέτης· το ποσό μένει χειροκίνητο.
  assert.equal(kimdisDiscountPct(5000, 4781.16), null);
  assert.equal(kimdisDiscountPct(4781.17, 4781.16), null, 'υπέρβαση ενός λεπτού είναι υπέρβαση');
  // Μέσα στην ανοχή του μισού λεπτού: καμία έκπτωση, ποτέ αρνητικό ποσοστό.
  assert.equal(kimdisDiscountPct(4781.164, 4781.16), 0);
});

test('η έκπτωση αντέχει άκυρες εισόδους', () => {
  assert.equal(kimdisDiscountPct(null, 100), null);
  assert.equal(kimdisDiscountPct(50, 0), null);
  assert.equal(kimdisDiscountPct(50, null), null);
  assert.equal(kimdisDiscountPct(-1, 100), null);
});

test('ο έλεγχος μορφής ΑΔΑΜ δέχεται μόνο έγκυρες πράξεις', () => {
  for (const ok of ['25SYMV017115178', '24PROC014500000', '26REQ000000001', '25AWRD000000001']) {
    assert.ok(KIMDIS_ADAM_RE.test(ok), ok);
  }
  for (const bad of ['25SYMV01711517', '25XXXX017115178', 'SYMV017115178', '', '25symv017115178']) {
    assert.ok(!KIMDIS_ADAM_RE.test(bad), bad);
  }
});

test('η edge function δεν εκθέτει μυστικά και δεν χαλαρώνει την πολιτική', () => {
  assert.match(edgeFn, /cerpp\.eprocurement\.gov\.gr\/khmdhs-opendata/);
  assert.doesNotMatch(edgeFn, /Deno\.env\.get/, 'το ΚΗΜΔΗΣ Open Data δεν απαιτεί κλειδί');
  assert.doesNotMatch(edgeFn, /service_role|sb_secret_/i);
  assert.match(edgeFn, /AbortController/, 'η κλήση προς το κρατικό API πρέπει να έχει χρονικό όριο');
});

test('η CSP δεν χρειάστηκε να ανοίξει για το ΚΗΜΔΗΣ', () => {
  const csp = source.match(/<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"/i)[1];
  const connect = csp.match(/connect-src ([^;]+)/)[1];
  assert.ok(!/eprocurement/.test(connect),
    'η κλήση περνά από την edge function στον host του Supabase — το connect-src μένει κλειστό');
  assert.match(source, /sb\.functions\.invoke\("kimdis-lookup"/);
});
