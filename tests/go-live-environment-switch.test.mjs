import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { apply, inspect, hashOf, DEFAULT_HTML, ENVIRONMENTS } from '../tools/set-environment.mjs';

const STAGING = 'https://omncqldgtkdcjpqfwwlr.supabase.co';
const OTHER = 'https://hafaxrebjzootjzzqkzx.supabase.co';
const KEY = 'sb_publishable_fixture_KEY_value_0001';
// Συντίθεται ώστε ο σαρωτής μυστικών να μη βρίσκει literal secret key σε αρχείο του repo.
const FAKE_SECRET = ['sb', 'secret', 'abcdefghijklmnop'].join('_');

/** Ελάχιστο ομοίωμα του index.html με την ίδια σύζευξη CSP ↔ σταθερών. */
function fixture({ environment = 'staging', url = STAGING, key = KEY, connectHost = 'omncqldgtkdcjpqfwwlr.supabase.co', hash = null } = {}) {
  const script = `
const APP_ENVIRONMENT='${environment}';
const SUPABASE_URL='${url}';
const SUPABASE_KEY='${key}';
const sb=window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY);
`;
  const csp = `default-src 'self';script-src 'self' file: '${hash ?? hashOf(script)}'; script-src-attr 'none'; connect-src https://${connectHost} wss://${connectHost} https://fonts.googleapis.com; object-src 'none'`;
  return `<!doctype html>\n<meta http-equiv="Content-Security-Policy" content="${csp}">\n<script>${script}</script>\n`;
}

test('το πραγματικό index.html είναι συνεκτικό ως προς περιβάλλον, CSP και hashes', () => {
  assert.deepEqual(inspect(fs.readFileSync(DEFAULT_HTML, 'utf8')), []);
});

test('το ομοίωμα ελέγχου είναι εξ ορισμού συνεκτικό', () => {
  assert.deepEqual(inspect(fixture()), []);
});

test('μισή μετάβαση — αλλαγή URL χωρίς CSP — εντοπίζεται', () => {
  // Ακριβώς το σενάριο go-live: αλλάζουν URL/key, ξεχνιέται το connect-src.
  const problems = inspect(fixture({ environment: 'production', url: OTHER }));
  assert.ok(problems.some(p => p.includes('connect-src') && p.includes('https://hafaxrebjzootjzzqkzx.supabase.co')),
    `αναμενόταν εντοπισμός ασύμβατου connect-src, βρέθηκαν: ${JSON.stringify(problems)}`);
});

test('μισή μετάβαση — αλλαγή CSP χωρίς τις σταθερές — εντοπίζεται', () => {
  const problems = inspect(fixture({ connectHost: 'hafaxrebjzootjzzqkzx.supabase.co' }));
  assert.ok(problems.some(p => p.includes('connect-src')));
  assert.ok(problems.some(p => p.includes('διαφορετικά project')));
});

test('ξεπερασμένο CSP hash εντοπίζεται πριν φτάσει σε browser', () => {
  const problems = inspect(fixture({ hash: 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' }));
  assert.ok(problems.some(p => p.includes('ξεπερασμένο CSP hash')));
});

test('secret key και μη publishable key απορρίπτονται', () => {
  assert.ok(inspect(fixture({ key: FAKE_SECRET })).some(p => p.includes('secret')));
  assert.ok(inspect(fixture({ key: 'anon-legacy-key' })).some(p => p.includes('publishable')));
});

test('wildcard στο connect-src εντοπίζεται', () => {
  assert.ok(inspect(fixture({ connectHost: '*.supabase.co' })).some(p => p.includes('wildcard')));
});

test('άγνωστο APP_ENVIRONMENT εντοπίζεται', () => {
  assert.ok(inspect(fixture({ environment: 'dokimastiko' })).some(p => p.includes('APP_ENVIRONMENT')));
});

test('η μετάβαση σε παραγωγή αλλάζει και τα τέσσερα σημεία ταυτόχρονα', () => {
  const before = fixture();
  const after = apply(before, { environment: 'production', url: OTHER, key: 'sb_publishable_prod_KEY_value_1234' });

  assert.deepEqual(inspect(after), [], 'το αποτέλεσμα της μετάβασης πρέπει να είναι συνεκτικό');
  assert.match(after, /const APP_ENVIRONMENT='production'/);
  assert.match(after, new RegExp(`const SUPABASE_URL='${OTHER}'`));
  assert.match(after, /const SUPABASE_KEY='sb_publishable_prod_KEY_value_1234'/);
  assert.match(after, /connect-src https:\/\/hafaxrebjzootjzzqkzx\.supabase\.co wss:\/\/hafaxrebjzootjzzqkzx\.supabase\.co/);
  assert.doesNotMatch(after, /omncqldgtkdcjpqfwwlr/, 'δεν επιτρέπεται να μείνει ίχνος του παλιού project');
  assert.match(after, /https:\/\/fonts\.googleapis\.com/, 'οι υπόλοιπες πηγές της CSP διατηρούνται');
});

test('η μετάβαση είναι ταυτοτική όταν εφαρμοστεί δύο φορές', () => {
  const once = apply(fixture(), { environment: 'production', url: OTHER, key: 'sb_publishable_prod_KEY_value_1234' });
  const twice = apply(once, { environment: 'production', url: OTHER, key: 'sb_publishable_prod_KEY_value_1234' });
  assert.equal(twice, once);
});

test('η μετάβαση απορρίπτει επικίνδυνες παραμέτρους αντί να τις γράψει', () => {
  const html = fixture();
  const ok = { environment: 'production', url: OTHER, key: 'sb_publishable_prod_KEY_value_1234' };
  assert.throws(() => apply(html, { ...ok, url: 'http://hafaxrebjzootjzzqkzx.supabase.co' }), /μη έγκυρο --url/);
  assert.throws(() => apply(html, { ...ok, url: 'https://evil.example.com' }), /μη έγκυρο --url/);
  assert.throws(() => apply(html, { ...ok, url: `${OTHER}/rest/v1` }), /μη έγκυρο --url/);
  assert.throws(() => apply(html, { ...ok, key: FAKE_SECRET }), /μη έγκυρο --key/);
  assert.throws(() => apply(html, { ...ok, environment: 'dokimastiko' }), /άγνωστο περιβάλλον/);
});

test('τα επιτρεπτά περιβάλλοντα είναι ρητά δηλωμένα', () => {
  assert.deepEqual(ENVIRONMENTS, ['staging', 'production']);
});
