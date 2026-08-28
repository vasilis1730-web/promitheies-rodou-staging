import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const edgeFn = fs.readFileSync(new URL('../supabase/functions/kimdis-lookup/index.ts', import.meta.url), 'utf8');

/* Οι κανόνες εξάγονται από το ίδιο το index.html: αν αλλάξουν εκεί χωρίς να
   αλλάξουν οι δοκιμές, το CI αποτυγχάνει. */
// Ο browser έχει το URL ως global· το vm context ξεκινά άδειο και πρέπει να δοθεί.
const sandbox = vm.createContext({ URL });
for (const [name, pattern] of [
  ['KIMDIS_ADAM_RE', /const KIMDIS_ADAM_RE=[^\n]+/],
  ['kimdisAfm', /const kimdisAfm=[^\n]+/],
  ['KIMDIS_BASE', /const KIMDIS_BASE=[^\n]+/],
  ['KIMDIS_KIND_PATH', /const KIMDIS_KIND_PATH=[^\n]+/],
  ['kimdisLinkFor', /function kimdisLinkFor\(value\)\{[\s\S]*?\n\}/],
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
const kimdisLinkFor = read('kimdisLinkFor');

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

test('χαρτογραφεί ΟΛΑ τα μεταδεδομένα που δίνει το ΚΗΜΔΗΣ', () => {
  const k = kimdisMapContract({
    ...SYMV,
    contractType: { key: '2', value: 'Υπηρεσίες' },
    procedureType: { key: '9', value: 'Απευθείας ανάθεση' },
    fundingDetails: { publicFundingRef: 'ΣΑΤΑ', publicFundingRefNum: '2026ΣΑΤΑ0001' },
    decisionRelatedAda: '6ΨΙΞΩ1Ρ-ΑΒΓ',
    paymentRefNo: ['26PAY015555555', '26PAY015555556']
  });
  assert.equal(k.cpv_code, '50413200-5');
  assert.match(k.cpv_label, /πυρόσβεσης/);
  assert.equal(k.legal_context, 'ν.4412/2016 - Βιβλίο Ι – κάτω των ορίων');
  assert.equal(k.contract_type, 'Υπηρεσίες');
  assert.equal(k.procedure_type, 'Απευθείας ανάθεση');
  assert.equal(k.signer, 'ΔΗΜΑΡΧΟΣ ΡΟΔΟΥ');
  assert.equal(k.funding, 'ΣΑΤΑ — 2026ΣΑΤΑ0001');
  assert.equal(k.ada, '6ΨΙΞΩ1Ρ-ΑΒΓ');
  assert.equal(k.notice_adam, '25PROC014500000');
  assert.equal(k.supplier_country, 'Ελλάδα');
  assert.equal(k.submission_date, '2026-03-11');
  assert.deepEqual(k.payments, ['26PAY015555555', '26PAY015555556']);
  assert.equal(k.cancelled, false);
});

test('εντοπίζει ακυρωμένη πράξη και νεότερη έκδοση', () => {
  const k = kimdisMapContract({ ...SYMV, cancelled: true, cancellationDate: '2026-05-01T00:00:00', nextRefNo: '26SYMV019999999' });
  assert.equal(k.cancelled, true);
  assert.equal(k.cancellation_date, '2026-05-01');
  assert.equal(k.next_ref, '26SYMV019999999');
});

test('η ΑΔΑ βρίσκεται και από εναλλακτικά πεδία', () => {
  assert.equal(kimdisMapContract({ contractRelatedADA: { number1: 'ΨΨΨ-123' } }).ada, 'ΨΨΨ-123');
  assert.equal(kimdisMapContract({ diavgeiaADA: 'ΩΩΩ-456' }).ada, 'ΩΩΩ-456');
});

test('οι εντολές πληρωμής είναι πάντα πίνακας', () => {
  // Οι πίνακες που φτιάχνονται μέσα στο vm context έχουν άλλο prototype, οπότε
  // ελέγχεται το είδος και το περιεχόμενο, όχι η ταυτότητα του αντικειμένου.
  for (const raw of [{}, { paymentRefNo: null }, { paymentRefNo: 'όχι πίνακας' }]) {
    const payments = kimdisMapContract(raw).payments;
    assert.ok(Array.isArray(payments));
    assert.equal(payments.length, 0);
  }
});

test('η καρτέλα εμφανίζει τα πεδία και η αποθήκευση περνά από ατομικό RPC', () => {
  for (const label of ['Τίτλος σύμβασης', 'Α/Α ΕΣΗΔΗΣ', 'CPV', 'Αναθέτουσα αρχή',
                       'Νομικό πλαίσιο', 'Διαδικασία', 'Υπογράφων', 'Χρηματοδότηση',
                       'ΑΔΑ απόφασης', 'ΑΔΑΜ διακήρυξης', 'Εντολές πληρωμής']) {
    assert.ok(source.includes('"' + label + '"'), 'λείπει το πεδίο ' + label + ' από την καρτέλα');
  }
  assert.match(source, /sb\.rpc\("set_contract_kimdis"/);
  // Το μήνυμα του server πρέπει να φτάνει στον χρήστη, όχι το γενικό «non-2xx».
  assert.match(source, /await error\.context\.json\(\)/);
});

test('ΑΔΑΜ γραμμένος στο πεδίο συνδέσμου γίνεται πραγματική διεύθυνση ΚΗΜΔΗΣ', () => {
  // Αυτό ακριβώς ήταν αποθηκευμένο και άνοιγε νέα καρτέλα με σφάλμα DNS.
  assert.equal(kimdisLinkFor('https://25SYMV018057506'),
    'https://cerpp.eprocurement.gov.gr/khmdhs-opendata/contract/attachment/25SYMV018057506');
  assert.equal(kimdisLinkFor('25SYMV018057506'),
    'https://cerpp.eprocurement.gov.gr/khmdhs-opendata/contract/attachment/25SYMV018057506');
  assert.match(kimdisLinkFor('24PROC014500000'), /\/notice\/attachment\/24PROC014500000$/);
  assert.match(kimdisLinkFor('26REQ000000001'), /\/request\/attachment\/26REQ000000001$/);
  assert.match(kimdisLinkFor('25AWRD000000001'), /\/award\/attachment\/25AWRD000000001$/);
});

test('πραγματική διεύθυνση διατηρείται αυτούσια', () => {
  assert.equal(kimdisLinkFor('https://www.eprocurement.gov.gr/kimds2/x?y=1'),
    'https://www.eprocurement.gov.gr/kimds2/x?y=1');
});

test('ό,τι δεν είναι αναγνωρίσιμο δεν γίνεται σύνδεσμος', () => {
  // Καλύτερα κανένας σύνδεσμος παρά σύνδεσμος που ανοίγει σελίδα σφάλματος.
  for (const bad of ['', null, undefined, '   ', 'https://xoris-teleia', 'σκέτο κείμενο',
                     'javascript:alert(1)', 'http://']) {
    assert.equal(kimdisLinkFor(bad), null, JSON.stringify(bad));
  }
});

test('η ετικέτα του συνδέσμου ξεχωρίζει από το κουμπί άντλησης', () => {
  assert.ok(source.includes('"Σύνδεσμος ΚΗΜΔΗΣ ↗"'), 'ο σύνδεσμος πρέπει να λέει ότι είναι σύνδεσμος');
  assert.ok(source.includes('"🔎 Άντληση από ΚΗΜΔΗΣ"'), 'το κουμπί άντλησης πρέπει να ξεχωρίζει');
  assert.ok(!source.includes('},"ΚΗΜΔΗΣ ↗")'), 'η παλιά διφορούμενη ετικέτα δεν πρέπει να έχει μείνει');
});

test('χαρτογραφεί σωστά πραγματική σύμβαση με μειωμένο ΦΠΑ νησιού', () => {
  const k = kimdisMapContract({
    title: 'ΑΝΑΓΟΜΩΣΗ ΠΥΡΟΣΒΕΣΤΗΡΩΝ',
    referenceNumber: '25SYMV018057506',
    aaht: '1007.E86105.0001',
    contractNumber: '9596/02-12-2025',
    contractSignedDate: '2025-12-02',
    submissionDate: '2025-12-02',
    organization: { key: '1007', value: 'ΔΗΜΟΣ ΛΕΡΟΥ' },
    legalContext: { key: '2', value: 'ν.4412/2016 - Βιβλίο Ι – κάτω των ορίων' },
    contractType: { key: '2', value: 'Υπηρεσίες' },
    procedureType: { key: '9', value: 'Απευθείας ανάθεση' },
    contractingDataDetails: {
      signers: { key: '1', value: 'ΤΙΜΟΘΕΟΣ ΚΩΤΤΑΚΗΣ - Δήμαρχος' },
      contractingMembersDataList: [
        { country: { key: 'GR', value: 'Ελλάδα' }, vatNumber: '801362883', name: 'GFS LEROS ΙΕΠΥΑ ΜΟΝΟΠ.ΙΚΕ' }
      ]
    },
    totalCostWithoutVAT: 4245.50,
    totalCostWithVAT: 4967.24,
    objectDetailsList: [{ vat: '17', cpvs: [{ key: '50413200-5', value: 'Υπηρεσίες επισκευής και συντήρησης εξοπλισμού πυρόσβεσης' }] }],
    decisionRelatedAda: 'ΨΑΑ1ΩΛΓ-81Β',
    paymentRefNo: ['25PAY018125670']
  });
  assert.equal(k.title, 'ΑΝΑΓΟΜΩΣΗ ΠΥΡΟΣΒΕΣΤΗΡΩΝ');
  assert.equal(k.aaht, '1007.E86105.0001', 'το Α/Α ΕΣΗΔΗΣ δεν είναι σκέτος αριθμός');
  assert.equal(k.protocol_no, '9596/02-12-2025');
  assert.equal(k.supplier_name, 'GFS LEROS ΙΕΠΥΑ ΜΟΝΟΠ.ΙΚΕ');
  assert.equal(k.supplier_afm, '801362883');
  assert.equal(k.supplier_country, 'Ελλάδα');
  assert.equal(k.net_total, 4245.50);
  assert.equal(k.gross_total, 4967.24);
  assert.equal(k.vat_rate, 17, 'ο μειωμένος συντελεστής νησιού πρέπει να γίνεται δεκτός');
  assert.equal(k.cpv_code, '50413200-5');
  assert.equal(k.organization, 'ΔΗΜΟΣ ΛΕΡΟΥ');
  assert.equal(k.signer, 'ΤΙΜΟΘΕΟΣ ΚΩΤΤΑΚΗΣ - Δήμαρχος');
  assert.equal(k.ada, 'ΨΑΑ1ΩΛΓ-81Β');
  assert.deepEqual([...k.payments], ['25PAY018125670']);
  // Η αξία με ΦΠΑ επαληθεύει τον συντελεστή: 4.245,50 × 1,17 = 4.967,235.
  // Το ΚΗΜΔΗΣ δημοσιεύει 4.967,24· ανοχή ενός λεπτού για τη στρογγυλοποίηση.
  assert.ok(Math.abs(k.net_total * (1 + k.vat_rate / 100) - k.gross_total) <= 0.01,
    'ο συντελεστής ΦΠΑ πρέπει να συμφωνεί με τα δύο δημοσιευμένα ποσά');
});

test('ο ανάδοχος καταχωρίζεται αυτόματα όταν λείπει από το μητρώο', () => {
  assert.match(source, /sb\.from\("mo_suppliers"\)\.insert\(\{[\s\S]{0,200}afm:k\.supplier_afm/,
    'το ΑΦΜ πρέπει να αποθηκεύεται ως ταυτότητα του αναδόχου');
  assert.ok(source.includes('καταχωρίστηκε «'), 'η αυτόματη καταχώριση πρέπει να αναφέρεται στον χρήστη');
});

test('υπάρχει λήψη του πρωτότυπου PDF της σύμβασης', () => {
  assert.ok(source.includes('"⬇ Σύμβαση (PDF)"'));
  assert.match(source, /function kimdisPdfFor\(adam\)/);
});

test('τα μεταδεδομένα ΚΗΜΔΗΣ φορτώνονται μαζί με τη σύμβαση', () => {
  assert.match(source, /discount_pct,vat_rate,kimdis,kimdis_fetched_at/,
    'χωρίς τη στήλη στο select, η κάρτα της μελέτης δεν θα τα έβλεπε ποτέ');
});
