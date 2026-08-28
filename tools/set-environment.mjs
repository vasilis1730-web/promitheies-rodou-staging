#!/usr/bin/env node
/**
 * Ενιαία μετάβαση περιβάλλοντος για το index.html.
 *
 * Το index.html δηλώνει το backend σε ΤΕΣΣΕΡΑ συζευγμένα σημεία:
 *
 *   1. const APP_ENVIRONMENT   — ρητή ονομασία περιβάλλοντος
 *   2. const SUPABASE_URL      — endpoint του project
 *   3. const SUPABASE_KEY      — publishable key του project
 *   4. CSP connect-src         — https:// και wss:// του ΙΔΙΟΥ host
 *
 * Επιπλέον, τα (1)-(3) βρίσκονται μέσα σε inline <script> που είναι
 * καρφιτσωμένο με 'sha256-...' στη CSP: κάθε αλλαγή τους ακυρώνει το hash
 * και, χωρίς επανυπολογισμό, ο browser μπλοκάρει ΟΛΟΚΛΗΡΟ το script.
 *
 * Αυτό το εργαλείο εκτελεί και τις τέσσερις αλλαγές μαζί με τον
 * επανυπολογισμό των hashes, ώστε η μετάβαση να μην μπορεί να μείνει μισή.
 *
 *   node tools/set-environment.mjs --check
 *   node tools/set-environment.mjs --env production \
 *        --url https://xxxxxxxxxxxxxxxxxxxx.supabase.co \
 *        --key sb_publishable_XXXX
 */
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ENVIRONMENTS = Object.freeze(['staging', 'production']);
const HOST_PATTERN = /^[a-z0-9]{20}\.supabase\.co$/;
const KEY_PATTERN = /^sb_publishable_[A-Za-z0-9._-]{10,}$/;
const INLINE_SCRIPT = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
const CSP_META = /(<meta\s+http-equiv="Content-Security-Policy"\s+content=")([^"]+)(")/i;

export const DEFAULT_HTML = fileURLToPath(new URL('../index.html', import.meta.url));

const read = file => fs.readFileSync(file, 'utf8');

function cspOf(html) {
  const match = html.match(CSP_META);
  if (!match) throw new Error('δεν βρέθηκε meta Content-Security-Policy στο index.html');
  return match[2];
}

function inlineScriptsOf(html) {
  return [...html.matchAll(INLINE_SCRIPT)].map(m => m[1]);
}

export function hashOf(script) {
  return 'sha256-' + crypto.createHash('sha256').update(script, 'utf8').digest('base64');
}

function constantOf(html, name) {
  const match = html.match(new RegExp(`const ${name}\\s*=\\s*'([^']*)'`));
  return match ? match[1] : null;
}

function hostOf(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:') return null;
    if (parsed.pathname !== '/' || parsed.search || parsed.hash) return null;
    return parsed.host;
  } catch {
    return null;
  }
}

/** Επιστρέφει τη λίστα ασυνεπειών. Κενή λίστα σημαίνει συνεκτικό index.html. */
export function inspect(html) {
  const problems = [];
  const environment = constantOf(html, 'APP_ENVIRONMENT');
  const url = constantOf(html, 'SUPABASE_URL');
  const key = constantOf(html, 'SUPABASE_KEY');
  const csp = cspOf(html);

  if (!environment) problems.push('λείπει η σταθερά APP_ENVIRONMENT');
  else if (!ENVIRONMENTS.includes(environment)) {
    problems.push(`άγνωστο APP_ENVIRONMENT: ${environment} (επιτρεπτά: ${ENVIRONMENTS.join(', ')})`);
  }

  if (!url) problems.push('λείπει η σταθερά SUPABASE_URL');
  if (!key) problems.push('λείπει η σταθερά SUPABASE_KEY');
  if (key && !KEY_PATTERN.test(key)) problems.push('το SUPABASE_KEY δεν είναι publishable key');
  if (/sb_secret_/i.test(html)) problems.push('το index.html περιέχει secret key');

  const host = url ? hostOf(url) : null;
  if (url && !host) problems.push(`μη έγκυρο SUPABASE_URL: ${url} (αναμένεται https://<ref>.supabase.co χωρίς διαδρομή)`);
  if (host && !HOST_PATTERN.test(host)) problems.push(`μη αναμενόμενος host Supabase: ${host}`);

  const connectSrc = csp.match(/connect-src ([^;]+)/)?.[1]?.trim();
  if (!connectSrc) problems.push('η CSP δεν ορίζει connect-src');
  else if (host) {
    for (const scheme of ['https', 'wss']) {
      const origin = `${scheme}://${host}`;
      if (!connectSrc.split(/\s+/).includes(origin)) {
        problems.push(`η CSP connect-src δεν περιλαμβάνει ${origin} — το index.html δείχνει αλλού από ό,τι επιτρέπει η CSP`);
      }
    }
  }
  if (connectSrc && /\*/.test(connectSrc)) problems.push('η CSP connect-src περιέχει wildcard');

  // Καμία άλλη εγκατάσταση Supabase δεν πρέπει να έχει μείνει πίσω.
  const hosts = new Set([...html.matchAll(/([a-z0-9]{20})\.supabase\.co/g)].map(m => m[1]));
  if (host && hosts.size > 1) {
    problems.push(`το index.html αναφέρεται σε ${hosts.size} διαφορετικά project Supabase: ${[...hosts].join(', ')}`);
  }

  const scripts = inlineScriptsOf(html);
  for (const script of scripts) {
    const hash = hashOf(script);
    if (!csp.includes(`'${hash}'`)) {
      problems.push(`ξεπερασμένο CSP hash: λείπει το ${hash} — ο browser θα μπλοκάρει το inline script`);
    }
  }

  if (!/createClient\(SUPABASE_URL\s*,\s*SUPABASE_KEY\)/.test(html)) {
    problems.push('ο client Supabase δεν αρχικοποιείται από τις σταθερές SUPABASE_URL/SUPABASE_KEY');
  }

  return problems;
}

/** Εφαρμόζει το νέο περιβάλλον και επιστρέφει το νέο περιεχόμενο. */
export function apply(html, { environment, url, key }) {
  if (!ENVIRONMENTS.includes(environment)) {
    throw new Error(`άγνωστο περιβάλλον: ${environment} (επιτρεπτά: ${ENVIRONMENTS.join(', ')})`);
  }
  const host = hostOf(url);
  if (!host || !HOST_PATTERN.test(host)) {
    throw new Error(`μη έγκυρο --url: ${url} (αναμένεται https://<ref>.supabase.co χωρίς διαδρομή)`);
  }
  if (!KEY_PATTERN.test(key)) {
    throw new Error('μη έγκυρο --key: αναμένεται publishable key (sb_publishable_...)');
  }

  let next = html;
  for (const [name, value] of [['APP_ENVIRONMENT', environment], ['SUPABASE_URL', url], ['SUPABASE_KEY', key]]) {
    const pattern = new RegExp(`(const ${name}\\s*=\\s*')[^']*(')`);
    if (!pattern.test(next)) throw new Error(`δεν βρέθηκε η σταθερά ${name} στο index.html`);
    next = next.replace(pattern, `$1${value}$2`);
  }

  // Τα hashes υπολογίζονται ΜΕΤΑ τις αλλαγές των σταθερών και πριν γραφτεί η CSP.
  const hashes = inlineScriptsOf(next).map(hashOf);
  next = next.replace(CSP_META, (_all, open, csp, close) => {
    let updated = csp.replace(/connect-src ([^;]+)/, (all, sources) => {
      const rest = sources.trim().split(/\s+/).filter(src => !/supabase\.co$/.test(src));
      return `connect-src https://${host} wss://${host} ${rest.join(' ')}`.trim();
    });
    let index = 0;
    updated = updated.replace(/'sha256-[A-Za-z0-9+/=]+'/g, () => {
      const hash = hashes[index++];
      return hash ? `'${hash}'` : '';
    });
    if (index !== hashes.length) {
      throw new Error(`η CSP δηλώνει ${index} hashes αλλά το index.html έχει ${hashes.length} inline scripts`);
    }
    return `${open}${updated}${close}`;
  });

  return next;
}

function parseArgs(argv) {
  const args = { check: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--check') args.check = true;
    else if (arg === '--env') args.environment = argv[++i];
    else if (arg === '--url') args.url = argv[++i];
    else if (arg === '--key') args.key = argv[++i];
    else if (arg === '--file') args.file = argv[++i];
    else throw new Error(`άγνωστη παράμετρος: ${arg}`);
  }
  return args;
}

function main(argv) {
  const args = parseArgs(argv);
  const file = args.file ? path.resolve(args.file) : DEFAULT_HTML;
  const html = read(file);

  if (args.check || (!args.environment && !args.url && !args.key)) {
    const problems = inspect(html);
    if (problems.length) {
      console.error('✖ Ασυνεπής ρύθμιση περιβάλλοντος:');
      for (const problem of problems) console.error(`  - ${problem}`);
      process.exitCode = 1;
      return;
    }
    console.log(`✓ ${constantOf(html, 'APP_ENVIRONMENT')} · ${constantOf(html, 'SUPABASE_URL')} · CSP και hashes συνεπή`);
    return;
  }

  for (const required of ['environment', 'url', 'key']) {
    if (!args[required]) throw new Error(`λείπει η παράμετρος --${required === 'environment' ? 'env' : required}`);
  }

  const next = apply(html, args);
  const problems = inspect(next);
  if (problems.length) {
    console.error('✖ Η αλλαγή δεν παρήγαγε συνεπές αποτέλεσμα και δεν γράφτηκε:');
    for (const problem of problems) console.error(`  - ${problem}`);
    process.exitCode = 1;
    return;
  }
  if (next === html) {
    console.log('· Καμία αλλαγή: το index.html δείχνει ήδη εκεί.');
    return;
  }
  fs.writeFileSync(file, next);
  console.log(`✓ ${path.basename(file)} → ${args.environment} · ${args.url}`);
  console.log('  Ενημερώθηκαν: APP_ENVIRONMENT, SUPABASE_URL, SUPABASE_KEY, CSP connect-src, CSP script hashes.');
  console.log('  Εκτέλεσε "npm test" πριν την ανάρτηση.');
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(`✖ ${error.message}`);
    process.exitCode = 1;
  }
}
