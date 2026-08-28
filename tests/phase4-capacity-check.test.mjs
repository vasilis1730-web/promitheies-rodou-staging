import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import { PGlite } from '@electric-sql/pglite';

const capacityCheck = fs.readFileSync(new URL('../supabase/120_PHASE4_CAPACITY_CHECK.sql', import.meta.url), 'utf8');
const appSource = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');

// Σχήμα του ΠΑΛΙΟΥ παραγωγικού: μόνο ό,τι υπήρχε πριν τη σειρά v36.3+.
// Κανένα award_groups, record_status ή RPC — ακριβώς όπως το περιγράφει το ΒΗΜΑ4.
const LEGACY_SCHEMA = `
create table public.municipal_units(id bigint primary key, name text not null, short_name text);
create table public.procurement_groups(id bigint primary key, code text not null, name text not null);
create table public.locked_studies(
  id bigint primary key,
  municipal_unit_id bigint not null references public.municipal_units(id),
  group_id bigint not null references public.procurement_groups(id),
  net_total numeric not null
);
insert into public.municipal_units(id,name,short_name) values
  (1,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΡΧΑΓΓΕΛΟΥ','ΑΡΧΑΓΓΕΛΟΥ'),
  (2,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ','ΑΤΑΒΥΡΟΥ'),
  (3,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΦΑΝΤΟΥ','ΑΦΑΝΤΟΥ'),
  (4,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΙΑΛΥΣΟΥ','ΙΑΛΥΣΟΥ'),
  (5,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΛΛΙΘΕΑΣ','ΚΑΛΛΙΘΕΑΣ'),
  (6,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΜΕΙΡΟΥ','ΚΑΜΕΙΡΟΥ'),
  (7,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΛΙΝΔΙΩΝ','ΛΙΝΔΙΩΝ'),
  (8,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ','ΝΟΤΙΑΣ ΡΟΔΟΥ'),
  (9,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΠΕΤΑΛΟΥΔΩΝ','ΠΕΤΑΛΟΥΔΩΝ'),
  (10,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ','ΡΟΔΟΥ'),
  (11,'ΔΗΜΟΣ ΡΟΔΟΥ','ΔΗΜΟΣ ΡΟΔΟΥ');
insert into public.procurement_groups(id,code,name) values
  (10,'electrical','Ηλεκτρολογικό υλικό'),
  (20,'plumbing','Υδραυλικό υλικό');
`;

async function report(db) {
  const results = await db.exec(capacityCheck);
  const rows = results.at(-1).rows;
  return JSON.parse(rows[0].anafora);
}

async function withDb(studies, fn) {
  const db = new PGlite();
  try {
    await db.exec(LEGACY_SCHEMA);
    if (studies.length) {
      await db.exec(`insert into public.locked_studies(id,municipal_unit_id,group_id,net_total) values ${
        studies.map((s, i) => `(${i + 1},${s.unit},${s.group},${s.net})`).join(',')
      };`);
    }
    await fn(db);
  } finally {
    await db.close();
  }
}

test('η αντιστοίχιση Δ.Ε. σε ομάδες αναπαράγει την επίσημη κατανομή του Δήμου', async () => {
  await withDb([], async db => {
    const result = await report(db);
    assert.equal(result.antistoixisi.entotites_pou_katanemithikan, 10);
    assert.deepEqual(result.antistoixisi.agnoristes_entotites, []);
    assert.equal(result.antistoixisi.kentriki_monada_pou_exairethike.name, 'ΔΗΜΟΣ ΡΟΔΟΥ');

    const byGroup = Object.fromEntries(result.antistoixisi.ana_omada.map(g => [g.omada, g.enotites]));
    assert.deepEqual(byGroup[1], ['ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ']);
    assert.equal(byGroup[2].length, 3);
    // Η ΝΟΤΙΑΣ ΡΟΔΟΥ ανήκει στην Ομάδα 3 και ΜΟΝΟ εκεί.
    assert.ok(byGroup[3].includes('ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ'));
    assert.ok(!byGroup[1].includes('ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ'));
    assert.equal(byGroup[4].length, 3);
    assert.equal(result.etymigoria, 'ΕΝΤΟΣ ΟΡΙΩΝ — η μεταφορά μπορεί να προχωρήσει στη Φάση 5.');
  });
});

test('ο κανόνας της §4.4 παράγει ψευδή ΥΠΕΡΒΑΣΗ στην Ομάδα 1 — ο διορθωμένος όχι', async () => {
  // Νότιας Ρόδου 20.000 (Ομάδα 3) · Ρόδου 15.000 (Ομάδα 1) · Δήμος Ρόδου 9.000 (εκτός κατανομής).
  await withDb([
    { unit: 8, group: 10, net: 20000 },
    { unit: 10, group: 10, net: 15000 },
    { unit: 11, group: 10, net: 9000 }
  ], async db => {
    const result = await report(db);
    const capacity = Object.fromEntries(result.xoritikotita.map(x => [x.omada, x]));

    assert.equal(Number(capacity[1].synolo_eur), 15000, 'η Ομάδα 1 έχει μόνο τη μελέτη της Δ.Ε. Ρόδου');
    assert.equal(capacity[1].katastasi, 'εντός');
    assert.equal(Number(capacity[3].synolo_eur), 20000);
    assert.equal(result.etymigoria, 'ΕΝΤΟΣ ΟΡΙΩΝ — η μεταφορά μπορεί να προχωρήσει στη Φάση 5.');

    // Ο παλιός κανόνας μετρούσε 20.000 + 15.000 + 9.000 = 44.000 στην Ομάδα 1.
    const delta = result.diafora_apo_kanona_4_4.find(d => d.omada === 1);
    assert.ok(delta, 'η αναφορά πρέπει να δείχνει τη διαφορά από τον κανόνα της §4.4');
    assert.equal(Number(delta.synolo_kanona_4_4_eur), 44000);
    assert.equal(Number(delta.synolo_diorthomeno_eur), 15000);
    assert.equal(Number(delta.diafora_eur), 29000);
  });
});

test('πραγματική υπέρβαση ορίου εντοπίζεται και σταματά τη μετάπτωση', async () => {
  await withDb([
    { unit: 4, group: 10, net: 19000 },   // Ιαλυσού
    { unit: 5, group: 10, net: 12000 },   // Καλλιθέας — ίδιο ομοειδές, ίδια ομάδα
    { unit: 3, group: 20, net: 5000 }     // Αφάντου, άλλο ομοειδές
  ], async db => {
    const result = await report(db);
    const electrical = result.xoritikotita.find(x => x.omada === 2 && x.kodikos === 'electrical');
    assert.equal(Number(electrical.synolo_eur), 31000);
    assert.equal(Number(electrical.ypoloipo_eur), -1000);
    assert.equal(electrical.katastasi, 'ΥΠΕΡΒΑΣΗ');
    assert.equal(electrical.meletes, 2);

    const plumbing = result.xoritikotita.find(x => x.omada === 2 && x.kodikos === 'plumbing');
    assert.equal(plumbing.katastasi, 'εντός', 'το όριο ισχύει ανά ομοειδές αντικείμενο');

    assert.match(result.etymigoria, /^ΥΠΕΡΒΑΣΗ/);
  });
});

test('αγνώριστη Δημοτική Ενότητα σταματά τον έλεγχο αντί να την αγνοήσει', async () => {
  await withDb([], async db => {
    await db.exec(`insert into public.municipal_units(id,name,short_name) values (12,'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΓΝΩΣΤΗ','ΑΓΝΩΣΤΗ');`);
    const result = await report(db);
    assert.equal(result.antistoixisi.agnoristes_entotites.length, 1);
    assert.equal(result.antistoixisi.agnoristes_entotites[0].name, 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΓΝΩΣΤΗ');
    assert.match(result.etymigoria, /^ΣΤΟΠ/);
  });
});

test('ο έλεγχος σταματά με σαφές μήνυμα όταν λείπει απαιτούμενη στήλη', async () => {
  const db = new PGlite();
  try {
    await db.exec(LEGACY_SCHEMA);
    await db.exec('alter table public.locked_studies drop column net_total;');
    await assert.rejects(() => db.exec(capacityCheck), /λείπουν απαιτούμενες στήλες.*net_total/s);
  } finally {
    await db.close();
  }
});

test('ο έλεγχος σταματά όταν λείπει απαιτούμενος πίνακας', async () => {
  const db = new PGlite();
  try {
    await db.exec('create table public.municipal_units(id bigint primary key, name text, short_name text);');
    await assert.rejects(() => db.exec(capacityCheck), /λείπουν απαιτούμενοι πίνακες/);
  } finally {
    await db.close();
  }
});

test('η αντιστοίχιση του SQL συμφωνεί με τον κανόνα της εφαρμογής για κάθε γραφή', async () => {
  // Ο κανόνας εξάγεται από το ίδιο το index.html: αν αλλάξει εκεί χωρίς να
  // αλλάξει το SQL, το τεστ αποτυγχάνει.
  const names = [
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', 'Νότιας Ρόδου', 'ΝΟΤΙΑ ΡΟΔΟΣ',
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', 'Ρόδου',
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΤΑΒΥΡΟΥ', 'Ατταβύρου',
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΛΙΝΔΙΩΝ', 'Λίνδου',
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΙΑΛΥΣΟΥ', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΛΛΙΘΕΑΣ', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΦΑΝΤΟΥ',
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΡΧΑΓΓΕΛΟΥ', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΠΕΤΑΛΟΥΔΩΝ', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΜΕΙΡΟΥ'
  ];

  const sandbox = { window: {} };
  for (const fn of ['norm', 'canonicalAwardUnitCodeForUnit', 'canonicalAwardGroupNoForUnit']) {
    const source = fn === 'norm'
      ? appSource.match(/const norm=[^\n]+/)?.[0]
      : appSource.match(new RegExp(`function ${fn}\\(unit\\)\\{[\\s\\S]*?\\n\\}`))?.[0];
    assert.ok(source, `δεν βρέθηκε ο κανόνας ${fn} στο index.html`);
    vm.runInNewContext(source, sandbox);
  }

  const db = new PGlite();
  try {
    await db.exec(LEGACY_SCHEMA);
    await db.exec('delete from public.municipal_units;');
    await db.exec(`insert into public.municipal_units(id,name,short_name) values ${
      names.map((name, i) => `(${i + 1},'${name}',null)`).join(',')
    };`);
    const results = await db.exec(capacityCheck);
    const mapped = JSON.parse(results.at(-1).rows[0].anafora).antistoixisi.ana_omada;

    const sqlGroupOf = new Map();
    for (const group of mapped) for (const name of group.enotites) sqlGroupOf.set(name, group.omada);

    for (const [index, name] of names.entries()) {
      if (index + 1 === 11) continue; // η κεντρική μονάδα εξαιρείται εξ ορισμού
      const expected = sandbox.canonicalAwardGroupNoForUnit({ name, short_name: null });
      assert.equal(sqlGroupOf.get(name) ?? null, expected, `ασυμφωνία SQL/εφαρμογής για «${name}»`);
    }
  } finally {
    await db.close();
  }
});
