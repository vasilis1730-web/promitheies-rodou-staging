import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { installCurrentSchema } from '../tools/schema-diff-legacy.mjs';

const script = fs.readFileSync(new URL('../supabase/130_SET_GO_LIVE_USER_ROLES.sql', import.meta.url), 'utf8');

const ROSTER = [
  ['diakolios@rhodes.gr', 'central', 11],
  ['mkanakas@gmail.com', 'unit_user', 10],
  ['mkarikispromithies@gmail.com', 'unit_user', 10],
  ['abekiaris@rhodes.gr', 'central', 11]
];

/** Δημιουργεί λογαριασμούς Auth· το trigger on_auth_user_created φτιάχνει τα προφίλ. */
async function createAccounts(db, emails, { confirmed = true } = {}) {
  for (const email of emails) {
    await db.query(
      `insert into auth.users(id, email, email_confirmed_at) values (gen_random_uuid(), $1, $2)`,
      [email, confirmed ? new Date().toISOString() : null]
    );
  }
}

async function profileOf(db, email) {
  const result = await db.query(`
    select p.role::text as role, p.municipal_unit_id as unit, p.is_active as active
    from auth.users u join public.profiles p on p.id = u.id
    where lower(u.email) = lower($1)
  `, [email]);
  return result.rows[0];
}

test('το trigger δημιουργεί προφίλ χωρίς δικαιώματα — γι΄ αυτό χρειάζεται το αρχείο', async () => {
  const db = await installCurrentSchema();
  try {
    await createAccounts(db, ['diakolios@rhodes.gr']);
    const profile = await profileOf(db, 'diakolios@rhodes.gr');
    assert.equal(profile.role, 'viewer', 'ο νέος λογαριασμός ξεκινά ως viewer');
    assert.equal(profile.unit, null, 'χωρίς Δημοτική Ενότητα');
  } finally {
    await db.close();
  }
});

test('αποδίδει σωστά ρόλους και Δημοτικές Ενότητες στους τέσσερις χρήστες', async () => {
  const db = await installCurrentSchema();
  try {
    await createAccounts(db, ROSTER.map(([email]) => email));
    await db.exec(script);

    for (const [email, role, unit] of ROSTER) {
      const profile = await profileOf(db, email);
      assert.equal(profile.role, role, `ρόλος για ${email}`);
      assert.equal(profile.unit, unit, `Δ.Ε. για ${email}`);
      assert.equal(profile.active, true, `ενεργός ${email}`);
    }
  } finally {
    await db.close();
  }
});

test('είναι επαναλήψιμο — δεύτερη εκτέλεση δεν αλλάζει τίποτα', async () => {
  const db = await installCurrentSchema();
  try {
    await createAccounts(db, ROSTER.map(([email]) => email));
    await db.exec(script);
    const before = await db.query('select id, role::text as role, municipal_unit_id, updated_at from public.profiles order by id');
    await db.exec(script);
    const after = await db.query('select id, role::text as role, municipal_unit_id, updated_at from public.profiles order by id');
    assert.deepEqual(after.rows, before.rows, 'ούτε το updated_at δεν πρέπει να μετακινηθεί');
  } finally {
    await db.close();
  }
});

test('σταματά χωρίς καμία αλλαγή αν λείπει λογαριασμός', async () => {
  const db = await installCurrentSchema();
  try {
    // Λείπει ο τέταρτος: ο διαχειριστής ξέχασε να τον φτιάξει στο Dashboard.
    await createAccounts(db, ROSTER.slice(0, 3).map(([email]) => email));
    await assert.rejects(() => db.exec(script), /Δεν υπάρχουν ακόμη λογαριασμοί για: abekiaris@rhodes\.gr/);
    await db.exec('rollback;'); // η αποτυχία αφήνει τη συναλλαγή σε abort

    // Καμία μερική εφαρμογή: οι υπόλοιποι μένουν viewer.
    for (const [email] of ROSTER.slice(0, 3)) {
      const profile = await profileOf(db, email);
      assert.equal(profile.role, 'viewer', `${email} δεν πρέπει να άλλαξε`);
    }
  } finally {
    await db.close();
  }
});

test('σταματά αν λογαριασμός δεν είναι επιβεβαιωμένος', async () => {
  const db = await installCurrentSchema();
  try {
    await createAccounts(db, ROSTER.slice(0, 3).map(([email]) => email));
    await createAccounts(db, ['abekiaris@rhodes.gr'], { confirmed: false });
    await assert.rejects(() => db.exec(script), /Μη επιβεβαιωμένοι λογαριασμοί: abekiaris@rhodes\.gr/);
  } finally {
    await db.close();
  }
});

test('δεν αγγίζει χρήστες εκτός λίστας', async () => {
  const db = await installCurrentSchema();
  try {
    await createAccounts(db, [...ROSTER.map(([email]) => email), 'allos@rhodes.gr']);
    await db.query(`update public.profiles set role='admin', municipal_unit_id=null
                    where id = (select id from auth.users where email='allos@rhodes.gr')`);
    await db.exec(script);
    const other = await profileOf(db, 'allos@rhodes.gr');
    assert.equal(other.role, 'admin', 'ο εκτός λίστας χρήστης μένει ανέπαφος');
    assert.equal(other.unit, null);
  } finally {
    await db.close();
  }
});

test('ο συνδυασμός ρόλου/Δ.Ε. του roster είναι έγκυρος κατά το constraint', () => {
  for (const [email, role, unit] of ROSTER) {
    const valid = (role === 'unit_user' && unit >= 1 && unit <= 10)
      || (role === 'central' && unit === 11)
      || (['admin', 'viewer'].includes(role) && unit === null);
    assert.ok(valid, `μη επιτρεπτός συνδυασμός για ${email}: ${role}/${unit}`);
  }
});
