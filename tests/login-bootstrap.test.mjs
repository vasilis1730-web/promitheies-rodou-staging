import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const source = fs.readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const html = source.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/gi, '');

function query(data, error = null) {
  const api = {
    select() { return api; },
    eq() { return api; },
    single: async () => ({ data, error }),
    maybeSingle: async () => ({ data, error })
  };
  return api;
}

function openLogin({ signInError = null, schemaVersion = null, schemaError = { message: 'RPC missing' }, client = true } = {}) {
  let session = null;
  let signInCalls = 0;
  const runtimeErrors = [];
  const dom = new JSDOM(html, {
    url: 'https://test.local/',
    runScripts: 'dangerously',
    pretendToBeVisual: true,
    beforeParse(window) {
      if (client) {
        window.supabase = { createClient: () => ({
          auth: {
            getSession: async () => ({ data: { session }, error: null }),
            signInWithPassword: async () => {
              signInCalls += 1;
              if (!signInError) session = { user: { id: 'user-1' } };
              return { error: signInError };
            },
            signOut: async () => ({ error: null })
          },
          from(table) {
            if (table === 'profiles') return query({ role: 'admin', municipal_unit_id: null, full_name: 'Δοκιμή', email: 'test@example.test' });
            if (table === 'user_app_permissions') return query({ can_supervise: true });
            return query([]);
          },
          rpc: async name => name === 'app_schema_version'
            ? { data: schemaVersion, error: schemaError }
            : { data: null, error: null }
        }) };
      }
      window.ExcelJS = {};
      window.ResizeObserver = class { observe() {} disconnect() {} };
      window.confirm = () => true;
      window.prompt = () => null;
      window.open = () => null;
      window.addEventListener('error', event => runtimeErrors.push(event.error?.message || event.message));
    }
  });
  return { dom, runtimeErrors, getSignInCalls: () => signInCalls };
}

async function waitFor(predicate) {
  const started = Date.now();
  while (!predicate()) {
    if (Date.now() - started > 2000) throw new Error('Timeout while waiting for login result');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

test('η επιτυχής ταυτοποίηση με μη αναβαθμισμένη βάση εξηγείται μόνιμα στη φόρμα', async () => {
  const { dom, runtimeErrors, getSignInCalls } = openLogin();
  const { document } = dom.window;
  document.querySelector('#email').value = 'test@example.test';
  document.querySelector('#pass').value = 'secret';
  document.querySelector('#loginBtn').click();

  await waitFor(() => document.querySelector('#loginErr').classList.contains('show'));
  const message = document.querySelector('#loginErr').textContent;
  assert.match(message, /Η σύνδεση επιβεβαιώθηκε/);
  assert.match(message, /δεν φταίνε το email ή ο κωδικός/i);
  assert.match(message, /staging/i);
  assert.equal(document.querySelector('#login').classList.contains('hidden'), false);
  assert.equal(document.querySelector('#app').classList.contains('hidden'), true);
  assert.equal(document.querySelector('#loginBtn').disabled, false);
  assert.equal(document.querySelector('#loginBtn').textContent, 'Είσοδος');
  assert.equal(getSignInCalls(), 1);
  assert.deepEqual(runtimeErrors, []);
  dom.window.close();
});

test('τα λανθασμένα στοιχεία παραμένουν διακριτά από σφάλμα εκκίνησης', async () => {
  const { dom, runtimeErrors } = openLogin({ signInError: { message: 'Invalid login credentials' } });
  const { document } = dom.window;
  document.querySelector('#email').value = 'test@example.test';
  document.querySelector('#pass').value = 'wrong';
  document.querySelector('#loginBtn').click();

  await waitFor(() => /Λάθος email ή κωδικός/.test(document.querySelector('#loginErr').textContent));
  assert.equal(document.querySelector('#loginBtn').disabled, false);
  assert.deepEqual(runtimeErrors, []);
  dom.window.close();
});

test('αν λείπει η τοπική βιβλιοθήκη σύνδεσης το κουμπί δεν μένει αδρανές', async () => {
  const { dom, runtimeErrors } = openLogin({ client: false });
  const { document } = dom.window;
  await waitFor(() => document.querySelector('#loginErr').classList.contains('show'));
  assert.match(document.querySelector('#loginErr').textContent, /πλήρες αποσυμπιεσμένο πακέτο/i);
  assert.equal(typeof document.querySelector('#loginBtn').onclick, 'function');
  assert.deepEqual(runtimeErrors, []);
  dom.window.close();
});

test('το πακέτο περιλαμβάνει σαφή τοπική εκκίνηση και δεν χαλαρώνει τον έλεγχο σχήματος', () => {
  assert.match(source, /location\.protocol==='file:'/);
  assert.match(source, /start-local\.bat/);
  assert.match(source, /REQUIRED_SCHEMA_VERSION='36\.6\.4'/);
  assert.match(source, /permissions_schema_missing/);
  assert.match(source, /schema_check_missing/);
  assert.match(source, /schema_mismatch/);
  assert.ok(fs.existsSync(new URL('../start-local.bat', import.meta.url)));
  assert.ok(fs.existsSync(new URL('../local-server.mjs', import.meta.url)));
});
