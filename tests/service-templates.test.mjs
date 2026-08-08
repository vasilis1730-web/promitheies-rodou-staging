import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const block = [...source.matchAll(/<script>([\s\S]*?)<\/script>/g)]
  .find(match => match[1].includes('window.ServiceTenderSpecs'));

function library() {
  assert.ok(block, 'δεν βρέθηκε το ενσωματωμένο block προτύπων');
  const context = { window: {} };
  vm.runInNewContext(block[1], context);
  return context.window.ServiceTenderSpecs;
}

test('υπάρχει αυτοτελές πλήρες πρότυπο για καθεμία από τις 8 ομάδες υπηρεσιών', () => {
  const specs = library();
  assert.equal(specs.version, '2.0');
  assert.deepEqual(Object.keys(specs.LIB), ['SRV01', 'SRV02', 'SRV03', 'SRV04', 'SRV05', 'SRV06', 'SRV07', 'SRV08']);

  for (const code of Object.keys(specs.LIB)) {
    const group = specs.getGroup({ code, name: code });
    assert.ok(group.title.length > 20, `${code}: τίτλος`);
    assert.ok(group.cpv.length >= 10, `${code}: CPV`);
    assert.ok(group.purpose.length > 20, `${code}: σκοπός`);
    for (const key of ['framework', 'technical', 'special', 'evidence', 'acceptance']) {
      assert.ok(Array.isArray(group[key]) && group[key].length >= 2, `${code}: ${key}`);
    }
    assert.ok(group.warranty.length > 20, `${code}: ευθύνη αποκατάστασης`);
  }
});

test('τα ειδικά πρότυπα περιέχουν τις κρίσιμες επικαιροποιήσεις και όχι το παλιό override αγοράς', () => {
  const specs = library();
  const hvac = JSON.stringify(specs.getGroup({ code: 'SRV01' }));
  const fire = JSON.stringify(specs.getGroup({ code: 'SRV06' }));
  const lifts = JSON.stringify(specs.getGroup({ code: 'SRV07' }));

  assert.match(hvac, /2024\/573/);
  assert.match(hvac, /2024\/2215/);
  assert.doesNotMatch(hvac, /517\/2014|2015\/2067|EPREL|ενεργειακή ετικέτα/i);
  assert.match(fire, /ανά δεκαετία/);
  assert.match(fire, /ανά πενταετία/);
  assert.match(lifts, /δύο επισκέψεις κάθε μήνα/);
  assert.match(lifts, /αριθμό απογραφής/i);
});

test('άγνωστη μελλοντική ομάδα υπηρεσιών χρησιμοποιεί ασφαλές γενικό πρότυπο', () => {
  const specs = library();
  const fallback = specs.getGroup({ code: 'SRV99', name: 'Νέα δοκιμαστική υπηρεσία' });
  assert.match(fallback.title, /ΔΟΚΙΜΑΣΤΙΚ/);
  assert.ok(fallback.technical.length >= 3);
  assert.ok(fallback.acceptance.length >= 3);
});
