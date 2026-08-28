import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');

const sandbox = vm.createContext({});
for (const [name, pattern] of [
  ['groupUsageTint', /function groupUsageTint\(pct\)\{[\s\S]*?\n\}/]
]) {
  const code = source.match(pattern)?.[0];
  assert.ok(code, `δεν βρέθηκε ο κανόνας ${name} στο index.html`);
  vm.runInContext(code, sandbox);
}
const groupUsageTint = vm.runInContext('groupUsageTint', sandbox);

test('η απόχρωση κλιμακώνεται με την απορρόφηση του ορίου', () => {
  const low = groupUsageTint(10), mid = groupUsageTint(75), high = groupUsageTint(95), full = groupUsageTint(100);
  assert.match(low, /^rgba\(37,99,235/, 'μέχρι 70% μπλε — άνετο περιθώριο');
  assert.match(mid, /^rgba\(217,119,6/, '70–90% πορτοκαλί — προσοχή');
  assert.match(high, /^rgba\(220,38,38/, '90%+ κόκκινο');
  assert.match(full, /^rgba\(220,38,38,\.30\)/, 'στο όριο, το εντονότερο κόκκινο');
  assert.notEqual(high, full, 'το εξαντλημένο όριο πρέπει να ξεχωρίζει από το σχεδόν εξαντλημένο');
});

test('τα όρια των ζωνών είναι σαφή, χωρίς κενά', () => {
  assert.equal(groupUsageTint(69.9), groupUsageTint(0));
  assert.equal(groupUsageTint(70), groupUsageTint(89.9));
  assert.notEqual(groupUsageTint(69.9), groupUsageTint(70));
  assert.notEqual(groupUsageTint(89.9), groupUsageTint(90));
  assert.notEqual(groupUsageTint(99.9), groupUsageTint(100));
});

test('η απορρόφηση μετριέται σε ΟΛΗ την ομάδα Δημοτικών Ενοτήτων', () => {
  const fn = source.slice(source.indexOf('async function loadGroupUsage'),
                          source.indexOf('function groupUsageTint'));
  // Το όριο των 30.000 € είναι κοινό για την τετράδα, όχι ανά Δ.Ε.
  assert.match(fn, /awardGroupUnitIds\(awardGroup\)/);
  assert.match(fn, /\.in\('municipal_unit_id',unitIds\)/);
  assert.match(fn, /\.eq\('request_year',YEAR\)/, 'το όριο είναι ετήσιο');
  assert.match(fn, /record_status==='cancelled'/, 'οι ακυρωμένες μελέτες δεν προσμετρώνται');
  assert.ok(!/\.eq\('group_id'/.test(fn),
    'πρέπει να φέρνει ΟΛΕΣ τις ομάδες μαζί, αλλιώς κάθε πλήκτρο θα έδειχνε την επιλεγμένη');
});

test('η κεντρική μονάδα δεν έχει όριο ομάδας και δεν βάφεται', () => {
  const fn = source.slice(source.indexOf('async function loadGroupUsage'),
                          source.indexOf('function groupUsageTint'));
  assert.match(fn, /cur\.unitId===CENTRAL_UNIT/);
});

test('η βαφή ανανεώνεται όποτε αλλάζουν οι κλειδωμένες μελέτες', () => {
  const fn = source.slice(source.indexOf('async function loadLocked'),
                          source.indexOf('function lockedNetSum'));
  assert.match(fn, /await loadGroupUsage\(\)/,
    'χωρίς αυτό, το ποσοστό θα έμενε στάσιμο μετά από νέο κλείδωμα');
});

test('το ποσοστό εμφανίζεται πάνω στο πλήκτρο με το υπόλοιπο σε tooltip', () => {
  const fn = source.slice(source.indexOf('function paintGrpNav'),
                          source.indexOf('function paintGrpNav') + 1600);
  assert.match(fn, /tag\.textContent=fmtN\(pct\)\+'%'/);
  assert.match(fn, /Απορρόφηση ομάδας Δ\.Ε\./);
  assert.match(fn, /υπόλοιπο/);
  assert.match(fn, /linear-gradient\(90deg/, 'το πλήκτρο γεμίζει από αριστερά');
  // Μηδενική απορρόφηση αφήνει το πλήκτρο όπως ήταν.
  assert.match(fn, /b\.style\.removeProperty\('background-image'\)/);
});
