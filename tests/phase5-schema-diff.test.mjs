import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { diff, installCurrentSchema, currentColumns, LEGACY_SNAPSHOT } from '../tools/schema-diff-legacy.mjs';

const snapshot = JSON.parse(fs.readFileSync(new URL(`../${LEGACY_SNAPSHOT}`, import.meta.url), 'utf8'));

/**
 * Οι στήλες που εμποδίζουν τη μεταφορά, όπως τεκμηριώνονται στο
 * docs/PHASE5_DATA_TRANSFER_PLAN.md. Αν μια μελλοντική migration προσθέσει
 * NOT NULL στήλη χωρίς default, το τεστ αποτυγχάνει και το σχέδιο μεταφοράς
 * πρέπει να ενημερωθεί ΠΡΙΝ τρέξει η μετάπτωση.
 */
const TEKMIRIOMENES_MPLOKARISTIKES = {
  mo_contracts: ['estimated_amount'],
  mo_contract_items: ['estimated_unit_price']
};

test('η diff εντοπίζει στήλη που πρέπει να συμπληρωθεί', () => {
  const report = diff(
    { t: { a: ['integer', false, false] } },
    { t: { a: ['integer', false, false], b: ['numeric', false, false] } }
  );
  assert.deepEqual(report.mustSupply, { t: ['b'] });
  assert.deepEqual(report.newOptional, {});
});

test('η diff ξεχωρίζει τις νέες στήλες που καλύπτονται από default ή null', () => {
  const report = diff(
    { t: { a: ['integer', false, false] } },
    { t: { a: ['integer', false, false], me_default: ['text', false, true], dexetai_null: ['text', true, false] } }
  );
  assert.deepEqual(report.mustSupply, {});
  assert.deepEqual(report.newOptional, { t: ['me_default', 'dexetai_null'] });
});

test('η diff εντοπίζει δεδομένα χωρίς προορισμό και αλλαγές τύπου', () => {
  const report = diff(
    { t: { palia: ['text', true, false], koini: ['integer', false, false] } },
    { t: { koini: ['numeric', false, false] } }
  );
  assert.deepEqual(report.dropped, { t: ['palia'] });
  assert.deepEqual(report.typeChanged, { t: [{ column: 'koini', apo: 'integer', se: 'numeric' }] });
});

test('η diff αγνοεί τη μετονομασία των enum ως αλλαγή τύπου', () => {
  const report = diff(
    { t: { status: ['USER-DEFINED', false, true] } },
    { t: { status: ['USER-DEFINED', false, true] } }
  );
  assert.deepEqual(report.typeChanged, {});
});

test('η diff εντοπίζει πίνακα που λείπει εντελώς', () => {
  const report = diff({ xameno: { a: ['text', true, false] } }, {});
  assert.deepEqual(report.missingTables, ['xameno']);
});

test('το τρέχον σχήμα δέχεται όλα τα δεδομένα του παλιού παραγωγικού', async () => {
  const db = await installCurrentSchema();
  try {
    const current = await currentColumns(db, Object.keys(snapshot.tables));
    const report = diff(snapshot.tables, current);

    assert.deepEqual(report.missingTables, [],
      'κάθε πίνακας του παλιού παραγωγικού πρέπει να υπάρχει στο νέο σχήμα');

    assert.deepEqual(report.mustSupply, TEKMIRIOMENES_MPLOKARISTIKES,
      'άλλαξαν οι στήλες που εμποδίζουν τη μεταφορά — ενημέρωσε το docs/PHASE5_DATA_TRANSFER_PLAN.md');

    assert.deepEqual(report.typeChanged, {},
      'αλλαγή τύπου στήλης απαιτεί ρητή μετατροπή κατά τη μεταφορά');

    // Γνωστή, αποδεκτή απώλεια: το locked_studies.created_at δεν υπάρχει πλέον.
    assert.deepEqual(report.dropped, { locked_studies: ['created_at'] });

    // Οι δύο στήλες που καθορίζουν τον έλεγχο ορίου πρέπει να υπάρχουν.
    assert.ok(report.newOptional.locked_studies.includes('award_group_id'));
    assert.ok(report.newOptional.locked_studies.includes('record_status'));
  } finally {
    await db.close();
  }
});
