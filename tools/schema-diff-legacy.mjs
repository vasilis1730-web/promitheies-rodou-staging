#!/usr/bin/env node
/**
 * Διαφορά σχήματος: ΠΑΛΙΟ παραγωγικό → τρέχουσα έκδοση (Φάση 5).
 *
 * Εγκαθιστά το πραγματικό installer και ΟΛΕΣ τις migrations σε προσωρινή
 * βάση PGlite, και το συγκρίνει με το καταγεγραμμένο σχήμα του παλιού
 * παραγωγικού (supabase/legacy_production_schema_*.json).
 *
 * Απαντά στο μόνο ερώτημα που έχει σημασία για τη μεταφορά δεδομένων:
 * ποιες στήλες πρέπει να συμπληρωθούν κατά τη μεταφορά και ποια δεδομένα
 * του παλιού δεν έχουν πού να πάνε.
 *
 *   node tools/schema-diff-legacy.mjs           # αναφορά για ανάγνωση
 *   node tools/schema-diff-legacy.mjs --json    # μηχαναγνώσιμο
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ROOT = fileURLToPath(new URL('../', import.meta.url));
const read = rel => fs.readFileSync(path.join(ROOT, rel), 'utf8');

export const LEGACY_SNAPSHOT = 'supabase/legacy_production_schema_2026-08-27.json';

/** Το installer και κάθε migration, με τη σειρά που τις ονομάζει το όνομα αρχείου. */
export function schemaFiles() {
  const dir = path.join(ROOT, 'supabase/migrations');
  const migrations = fs.readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
  return ['supabase/00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql', ...migrations.map(f => `supabase/migrations/${f}`)];
}

/** Στήνει το τρέχον σχήμα σε προσωρινή βάση και επιστρέφει τη σύνδεση. */
export async function installCurrentSchema() {
  const db = new PGlite();
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create role service_role nologin;
    create schema auth;
    create table auth.users (
      id uuid primary key default gen_random_uuid(), email text,
      raw_user_meta_data jsonb default '{}'::jsonb,
      encrypted_password text, email_confirmed_at timestamptz
    );
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('app.uid', true), '')::uuid
    $$;
    create function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
    create schema if not exists extensions;
  `);
  for (const file of schemaFiles()) {
    await db.exec(read(file).replace(/create extension if not exists pgcrypto;?/gi, ''));
  }
  return db;
}

/** Στήλες του τρέχοντος σχήματος: πίνακας -> στήλη -> [τύπος, δέχεται null, έχει default]. */
export async function currentColumns(db, tables) {
  const result = await db.query(`
    select table_name, column_name, data_type, is_nullable = 'YES' as nullable, column_default is not null as has_default
    from information_schema.columns
    where table_schema = 'public' and table_name = any($1)
    order by table_name, ordinal_position
  `, [tables]);
  const out = {};
  for (const row of result.rows) {
    (out[row.table_name] ??= {})[row.column_name] = [row.data_type, row.nullable, row.has_default];
  }
  return out;
}

/**
 * Συγκρίνει τα δύο σχήματα.
 * - `mustSupply`: υπάρχει μόνο στο νέο, δεν δέχεται null και δεν έχει default.
 *   Αν δεν δοθεί τιμή κατά τη μεταφορά, η εισαγωγή αποτυγχάνει.
 * - `newOptional`: υπάρχει μόνο στο νέο αλλά καλύπτεται από default ή null.
 * - `dropped`: υπάρχει μόνο στο παλιό — τα δεδομένα του δεν έχουν πού να πάνε.
 * - `typeChanged`: ίδια στήλη, διαφορετικός τύπος.
 * - `missingTables`: πίνακας του παλιού που δεν υπάρχει καθόλου στο νέο.
 */
export function diff(legacy, current) {
  const report = { mustSupply: {}, newOptional: {}, dropped: {}, typeChanged: {}, missingTables: [] };

  for (const [table, legacyCols] of Object.entries(legacy)) {
    const currentCols = current[table];
    if (!currentCols) { report.missingTables.push(table); continue; }

    for (const [column, [type, nullable, hasDefault]] of Object.entries(currentCols)) {
      if (column in legacyCols) continue;
      const target = (!nullable && !hasDefault) ? report.mustSupply : report.newOptional;
      (target[table] ??= []).push(column);
    }
    for (const [column, [legacyType]] of Object.entries(legacyCols)) {
      if (!(column in currentCols)) { (report.dropped[table] ??= []).push(column); continue; }
      const currentType = currentCols[column][0];
      // Το USER-DEFINED είναι enum· η ονομασία του τύπου διαφέρει ανά καταγραφή.
      if (currentType !== legacyType && legacyType !== 'USER-DEFINED' && currentType !== 'USER-DEFINED') {
        (report.typeChanged[table] ??= []).push({ column, apo: legacyType, se: currentType });
      }
    }
  }
  return report;
}

function render(report, counts) {
  const lines = [];
  const section = (title, body) => { lines.push('', title, '─'.repeat(title.length)); lines.push(...(body.length ? body : ['  (κανένα)'])); };

  section('ΠΙΝΑΚΕΣ ΠΟΥ ΛΕΙΠΟΥΝ ΑΠΟ ΤΟ ΝΕΟ ΣΧΗΜΑ', report.missingTables.map(t => `  ✖ ${t}`));

  section('ΣΤΗΛΕΣ ΠΟΥ ΠΡΕΠΕΙ ΝΑ ΣΥΜΠΛΗΡΩΘΟΥΝ ΚΑΤΑ ΤΗ ΜΕΤΑΦΟΡΑ', Object.entries(report.mustSupply).map(
    ([table, cols]) => `  ! ${table}: ${cols.join(', ')}   (${counts[table] ?? '?'} εγγραφές)`
  ));

  section('ΔΕΔΟΜΕΝΑ ΤΟΥ ΠΑΛΙΟΥ ΧΩΡΙΣ ΑΝΤΙΣΤΟΙΧΟ ΣΤΟ ΝΕΟ', Object.entries(report.dropped).map(
    ([table, cols]) => `  ✖ ${table}: ${cols.join(', ')}`
  ));

  section('ΑΛΛΑΓΕΣ ΤΥΠΟΥ', Object.entries(report.typeChanged).flatMap(
    ([table, items]) => items.map(i => `  ~ ${table}.${i.column}: ${i.apo} → ${i.se}`)
  ));

  section('ΝΕΕΣ ΣΤΗΛΕΣ ΜΕ DEFAULT Ή NULL (δεν εμποδίζουν τη μεταφορά)', Object.entries(report.newOptional).map(
    ([table, cols]) => `  + ${table}: ${cols.join(', ')}`
  ));

  return lines.join('\n');
}

async function main() {
  const snapshot = JSON.parse(read(LEGACY_SNAPSHOT));
  const db = await installCurrentSchema();
  try {
    const current = await currentColumns(db, Object.keys(snapshot.tables));
    const report = diff(snapshot.tables, current);
    if (process.argv.includes('--json')) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(`Διαφορά σχήματος: ${LEGACY_SNAPSHOT} → τρέχουσα έκδοση`);
      console.log(`Εγκαταστάθηκαν ${schemaFiles().length} αρχεία σχήματος.`);
      console.log(render(report, snapshot.row_counts));
    }
  } finally {
    await db.close();
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => { console.error(`✖ ${error.message}`); process.exitCode = 1; });
}
