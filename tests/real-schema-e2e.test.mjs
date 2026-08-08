/*
 * ΔΟΚΙΜΗ ΠΡΑΓΜΑΤΙΚΟΥ ΣΧΗΜΑΤΟΣ — v36.6.1
 *
 * Οι υπόλοιπες δοκιμές SQL χτίζουν απλοποιημένο συνθετικό schema. Έτσι δεν
 * εντόπισαν ότι στο ΠΡΑΓΜΑΤΙΚΟ 00_FULL_INSTALL έλειπε η στήλη
 * mo_orders.issued_by και ότι το CHECK του status δεν περιλάμβανε την
 * κατάσταση 'issued', με αποτέλεσμα να αποτυγχάνει ολόκληρη η ροή δελτίων.
 *
 * Η παρούσα δοκιμή εγκαθιστά το πραγματικό installer και ΟΛΕΣ τις migrations
 * με τη σειρά, και εκτελεί πλήρη κύκλο: κατανομή ομάδων -> κλείδωμα μελέτης
 * -> ανάθεση -> πρόχειρο δελτίο -> έκδοση -> παραλαβή -> πλήρης διαγραφή.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const MIGRATIONS = [
  '202608040001_award_groups',
  '202608050002_rls_immutable_audit',
  '202608050003_atomic_workflows',
  '202608050004_quantity_units_balances',
  '202608050005_xss_safe_excel',
  '202608050006_fixed_rhodes_award_groups',
  '202608050007_service_catalog',
  '202608050008_fix_save_request_status',
  '202608060001_fix_atavyros_unit_name',
  '202608060002_fix_south_rhodes_unit_name',
  '202608060003_fix_mo_orders_study_column',
  '202608060004_admin_study_templates_and_purge',
  '202608070001_fix_order_issue_and_purge_audit'
];

const ADMIN_ID = '11111111-1111-1111-1111-111111111111';

function read(relative) {
  return fs.readFileSync(new URL(relative, import.meta.url), 'utf8');
}

async function scalar(db, sql, params) {
  const result = await db.query(sql, params);
  const row = result.rows[0] || {};
  return row[Object.keys(row)[0]];
}

async function install() {
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
  const files = [
    '../supabase/00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql',
    ...MIGRATIONS.map(name => `../supabase/migrations/${name}.sql`)
  ];
  for (const file of files) {
    await db.exec(read(file).replace(/create extension if not exists pgcrypto;?/gi, ''));
  }
  await db.exec(`
    insert into auth.users(id, email) values ('${ADMIN_ID}', 'admin@rhodes.gr');
    insert into public.profiles(id, role, municipal_unit_id, full_name, email)
    values ('${ADMIN_ID}', 'admin', null, 'Διαχειριστής', 'admin@rhodes.gr')
    on conflict (id) do update set role = 'admin';
    select set_config('app.uid', '${ADMIN_ID}', false);
  `);
  return db;
}

async function activateAwardGroups(db, year) {
  const groups = await scalar(db, `
    with u as (select id, name from public.municipal_units where id <> 11)
    select jsonb_agg(x) from (
      select jsonb_build_object('group_no',1,'name','Ρόδου','municipal_unit_ids',
        (select coalesce(jsonb_agg(id),'[]'::jsonb) from u
         where name ilike '%ΡΟΔΟΥ%' and name not ilike '%ΝΟΤΙΑ%')) x
      union all select jsonb_build_object('group_no',2,'name','Ιαλυσού – Καλλιθέας – Αφάντου','municipal_unit_ids',
        (select coalesce(jsonb_agg(id),'[]'::jsonb) from u
         where name ilike '%ΙΑΛΥΣ%' or name ilike '%ΚΑΛΛΙΘΕ%' or name ilike '%ΑΦΑΝΤ%'))
      union all select jsonb_build_object('group_no',3,'name','Λίνδου – Νότιας Ρόδου – Αρχαγγέλου','municipal_unit_ids',
        (select coalesce(jsonb_agg(id),'[]'::jsonb) from u
         where name ilike '%ΛΙΝΔ%' or name ilike '%ΝΟΤΙΑ%' or name ilike '%ΑΡΧΑΓΓΕΛ%'))
      union all select jsonb_build_object('group_no',4,'name','Πεταλουδών – Καμείρου – Ατταβύρου','municipal_unit_ids',
        (select coalesce(jsonb_agg(id),'[]'::jsonb) from u
         where name ilike '%ΠΕΤΑΛΟΥΔ%' or name ilike '%ΚΑΜΕΙΡ%' or name ilike '%ΑΤΑΒΥΡ%' or name ilike '%ΑΤΤΑΒΥΡ%'))
    ) s
  `);
  await db.query(
    `select public.save_award_group_configuration($1,'123/2026',current_date,'ΩΑΒΓ-ΔΕΖ',30000,$2::jsonb)`,
    [year, JSON.stringify(groups)]
  );
  return groups;
}

test('το πραγματικό schema δέχεται installer και όλες τις migrations και οι 10 Δ.Ε. μπαίνουν σε 4 ομάδες', async () => {
  const db = await install();
  try {
    assert.equal(await scalar(db, `select public.app_schema_version()`), '36.6.1');
    assert.equal(Number(await scalar(db,
      `select count(*) from public.municipal_units where id <> 11`)), 10);

    await activateAwardGroups(db, 2026);

    assert.equal(Number(await scalar(db, `
      select count(*) from public.award_groups g
      join public.award_group_configurations c on c.id = g.configuration_id
      where c.budget_year = 2026 and c.is_active`)), 4);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.award_group_memberships m
      join public.award_group_configurations c on c.id = m.configuration_id
      where c.budget_year = 2026 and c.is_active`)), 10);
    // Καμία Δ.Ε. δεν βρίσκεται σε δύο ομάδες.
    assert.equal(Number(await scalar(db, `
      select count(*) from (
        select m.municipal_unit_id from public.award_group_memberships m
        join public.award_group_configurations c on c.id = m.configuration_id
        where c.budget_year = 2026 and c.is_active
        group by m.municipal_unit_id having count(*) > 1
      ) s`)), 0);
  } finally {
    await db.close();
  }
});

test('πλήρης κύκλος δελτίου στο πραγματικό schema: πρόχειρο, έκδοση, παραλαβή', async () => {
  const db = await install();
  try {
    await activateAwardGroups(db, 2026);

    const unitId = await scalar(db,
      `select id from public.municipal_units where id <> 11 order by id limit 1`);
    const groupId = await scalar(db,
      `select id from public.procurement_groups where domain = 'procurement' order by id limit 1`);
    const materialId = await scalar(db,
      `select id from public.materials where group_id = $1 and is_active order by id limit 1`, [groupId]);

    const lock = await scalar(db, `
      select public.lock_study_atomic(null, $1, $2, 2026, 'Δοκιμή', 'Προμηθευτής ΑΕ', null,
        jsonb_build_array(jsonb_build_object(
          'material_id', $3::text, 'quantity', 10, 'unit_price', 5.00, 'comments', null)))
    `, [unitId, groupId, materialId]);
    assert.equal(Number(lock.net), 50);

    const supplierId = await scalar(db,
      `insert into public.mo_suppliers(name, created_by) values ('Προμηθευτής ΑΕ', $1) returning id`, [ADMIN_ID]);
    const receiverId = await scalar(db,
      `insert into public.mo_receivers(name, created_by) values ('Παραλαμβάνων', $1) returning id`, [ADMIN_ID]);

    const contract = await scalar(db, `
      select public.save_contract_atomic(null, $1, $2, 'Σύμβαση δοκιμής', 'ΑΔΑΜ-1', 'ΠΡ-1',
        current_date, current_date + 90, 24)
    `, [lock.study_id, supplierId]);

    const item = (await db.query(
      `select id, unit_price from public.mo_contract_items where contract_id = $1 limit 1`,
      [contract.contract_id])).rows[0];
    const items = JSON.stringify([{
      contract_item_id: String(item.id), is_custom: false,
      description: 'Δοκιμή', unit: 'τεμ.', quantity: 2,
      unit_price: Number(item.unit_price), line_total: 2 * Number(item.unit_price)
    }]);

    // Πρόχειρο — απαιτεί υπαρκτή στήλη mo_orders.issued_by.
    const draft = await scalar(db, `
      select public.save_order_atomic(null, $1, current_date, $2, 'Αποθήκη', '', 24, $3::jsonb, false)
    `, [lock.study_id, String(receiverId), items]);
    assert.equal(draft.status, 'draft');

    // Έκδοση — απαιτεί CHECK που δέχεται την κατάσταση 'issued'.
    const issued = await scalar(db, `
      select public.save_order_atomic(null, $1, current_date, $2, 'Αποθήκη', '', 24, $3::jsonb, true)
    `, [lock.study_id, String(receiverId), items]);
    assert.equal(issued.status, 'issued');
    assert.match(issued.order_no, /^ΔΥ-2026-\d{2}-\d{3}$/);
    assert.equal(await scalar(db,
      `select issued_by from public.mo_orders where id = $1`, [issued.order_id]), ADMIN_ID);

    // Παραλαβή μέσω των επιτρεπτών μεταβάσεων issued -> sent -> received.
    await db.query(`select public.transition_order_status_atomic($1, 'sent', null)`, [issued.order_id]);
    await db.query(`select public.transition_order_status_atomic($1, 'received', null)`, [issued.order_id]);
    assert.equal(await scalar(db,
      `select status from public.mo_orders where id = $1`, [issued.order_id]), 'received');
  } finally {
    await db.close();
  }
});

test('η πλήρης διαγραφή στο πραγματικό schema αφαιρεί τα δελτία αλλά διατηρεί το ιστορικό', async () => {
  const db = await install();
  try {
    await activateAwardGroups(db, 2026);
    const unitId = await scalar(db,
      `select id from public.municipal_units where id <> 11 order by id limit 1`);
    const groupId = await scalar(db,
      `select id from public.procurement_groups where domain = 'procurement' order by id limit 1`);
    const materialId = await scalar(db,
      `select id from public.materials where group_id = $1 and is_active order by id limit 1`, [groupId]);

    const lock = await scalar(db, `
      select public.lock_study_atomic(null, $1, $2, 2026, 'Δοκιμή', null, null,
        jsonb_build_array(jsonb_build_object(
          'material_id', $3::text, 'quantity', 10, 'unit_price', 5.00, 'comments', null)))
    `, [unitId, groupId, materialId]);

    const supplierId = await scalar(db,
      `insert into public.mo_suppliers(name, created_by) values ('Προμηθευτής ΑΕ', $1) returning id`, [ADMIN_ID]);
    const receiverId = await scalar(db,
      `insert into public.mo_receivers(name, created_by) values ('Παραλαμβάνων', $1) returning id`, [ADMIN_ID]);
    const contract = await scalar(db, `
      select public.save_contract_atomic(null, $1, $2, 'Σύμβαση', null, null, current_date, current_date + 90, 24)
    `, [lock.study_id, supplierId]);
    const item = (await db.query(
      `select id, unit_price from public.mo_contract_items where contract_id = $1 limit 1`,
      [contract.contract_id])).rows[0];
    const items = JSON.stringify([{
      contract_item_id: String(item.id), is_custom: false, description: 'Δοκιμή',
      unit: 'τεμ.', quantity: 2, unit_price: Number(item.unit_price),
      line_total: 2 * Number(item.unit_price)
    }]);
    const issued = await scalar(db, `
      select public.save_order_atomic(null, $1, current_date, $2, 'Αποθήκη', '', 24, $3::jsonb, true)
    `, [lock.study_id, String(receiverId), items]);

    // Το πρότυπο επιβιώνει της διαγραφής της πηγής του.
    const template = await scalar(db,
      `select public.save_locked_study_as_template_atomic($1, 'Πρότυπο δοκιμής', null)`, [lock.study_id]);

    const purge = await scalar(db,
      `select public.admin_purge_locked_study_atomic($1, 'ΔΙΑΓΡΑΦΗ')`, [lock.study_id]);
    assert.equal(purge.deleted, true);
    assert.equal(Number(purge.deleted_orders), 1);
    assert.equal(Number(purge.deleted_contracts), 1);

    assert.equal(Number(await scalar(db,
      `select count(*) from public.locked_studies where id = $1`, [lock.study_id])), 0);
    assert.equal(Number(await scalar(db,
      `select count(*) from public.mo_orders where id = $1`, [issued.order_id])), 0);
    assert.equal(Number(await scalar(db,
      `select count(*) from public.study_templates where id = $1 and source_study_id is null`,
      [template.template_id])), 1);

    // Το αμετάβλητο ιστορικό διατηρείται και η διαγραφή καταγράφεται.
    assert.ok(Number(await scalar(db,
      `select count(*) from public.app_audit_log where entity_id = $1`, [lock.study_id])) > 0);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.app_audit_log
      where event_type = 'study_purged' and entity_id = $1`, [lock.study_id])), 1);
  } finally {
    await db.close();
  }
});

test('η ακυρωμένη μελέτη αποδεσμεύει το όριο της ομάδας και δεν δέχεται δελτία', async () => {
  const db = await install();
  try {
    await activateAwardGroups(db, 2026);
    const groupId = await scalar(db,
      `select id from public.procurement_groups where domain = 'procurement' order by id limit 1`);
    const materialId = await scalar(db,
      `select id from public.materials where group_id = $1 and is_active order by id limit 1`, [groupId]);

    // Δύο ΔΙΑΦΟΡΕΤΙΚΕΣ Δ.Ε. της ίδιας ομάδας μοιράζονται το όριο.
    const pair = (await db.query(`
      select m.municipal_unit_id from public.award_group_memberships m
      join public.award_group_configurations c on c.id = m.configuration_id
      where c.budget_year = 2026 and c.is_active
        and m.award_group_id = (
          select award_group_id from public.award_group_memberships m2
          join public.award_group_configurations c2 on c2.id = m2.configuration_id
          where c2.budget_year = 2026 and c2.is_active
          group by award_group_id having count(*) >= 2 limit 1)
      order by m.municipal_unit_id limit 2`)).rows.map(r => r.municipal_unit_id);
    assert.equal(pair.length, 2);

    const first = await scalar(db, `
      select public.lock_study_atomic(null, $1, $2, 2026, 'Α', null, null,
        jsonb_build_array(jsonb_build_object(
          'material_id', $3::text, 'quantity', 1, 'unit_price', 29000, 'comments', null)))
    `, [pair[0], groupId, materialId]);
    assert.equal(Number(first.net), 29000);

    // Η δεύτερη Δ.Ε. της ίδιας ομάδας δεν χωράει πλέον.
    await assert.rejects(db.query(`
      select public.lock_study_atomic(null, $1, $2, 2026, 'Β', null, null,
        jsonb_build_array(jsonb_build_object(
          'material_id', $3::text, 'quantity', 1, 'unit_price', 2000, 'comments', null)))
    `, [pair[1], groupId, materialId]), /υπερβαίνει το όριο/);

    // Μετά την ακύρωση, το ποσό αποδεσμεύεται.
    await db.query(`select public.cancel_locked_study_atomic($1, 'Δοκιμή ακύρωσης')`, [first.study_id]);
    const second = await scalar(db, `
      select public.lock_study_atomic(null, $1, $2, 2026, 'Β', null, null,
        jsonb_build_array(jsonb_build_object(
          'material_id', $3::text, 'quantity', 1, 'unit_price', 2000, 'comments', null)))
    `, [pair[1], groupId, materialId]);
    assert.equal(Number(second.net), 2000);
  } finally {
    await db.close();
  }
});

test('αντιγραφή αιτήματος στο πραγματικό schema — saved_versions δέχεται την ενέργεια copy', async () => {
  const db = await install();
  try {
    const groupId = await scalar(db,
      `select id from public.procurement_groups where domain = 'procurement' order by id limit 1`);
    const materialId = await scalar(db,
      `select id from public.materials where group_id = $1 and is_active order by id limit 1`, [groupId]);
    const units = (await db.query(
      `select id from public.municipal_units where id <> 11 order by id limit 2`)).rows.map(r => r.id);

    await db.query(`
      select public.save_unit_request_atomic(null, $1, $2, 2026, 'Πηγή', 'save',
        jsonb_build_array(jsonb_build_object(
          'material_id', $3::text, 'quantity', 3, 'unit_price', 4.5, 'comments', null)))
    `, [units[0], groupId, materialId]);

    const copied = await scalar(db, `
      select public.copy_unit_request_atomic($1, $2, $3, 2026, 'Αντίγραφο',
        jsonb_build_array(jsonb_build_object(
          'material_id', $4::text, 'quantity', 3, 'unit_price', 4.5, 'comments', null)))
    `, [units[0], units[1], groupId, materialId]);
    assert.ok(copied);
    assert.equal(Number(await scalar(db, `
      select count(*) from public.saved_versions where action = 'copy'`)), 1);
  } finally {
    await db.close();
  }
});

test('ο installer είναι αυτοτελώς σωστός — χωρίς το hotfix 202608070001', async () => {
  // Φρουρός παλινδρόμησης: τα τρία σφάλματα της v36.6.0 προήλθαν από τον ίδιο
  // τον installer. Αν κάποιο ξαναεμφανιστεί εκεί, αυτή η δοκιμή το πιάνει,
  // ακόμη κι αν η migration συνεχίζει να το διορθώνει εκ των υστέρων.
  const db = new PGlite();
  try {
    await db.exec(`
      create role anon nologin; create role authenticated nologin; create role service_role nologin;
      create schema auth;
      create table auth.users (
        id uuid primary key default gen_random_uuid(), email text,
        raw_user_meta_data jsonb default '{}'::jsonb,
        encrypted_password text, email_confirmed_at timestamptz);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('app.uid', true), '')::uuid $$;
      create function auth.jwt() returns jsonb language sql stable as $$ select '{}'::jsonb $$;
      create schema if not exists extensions;
    `);
    await db.exec(read('../supabase/00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql')
      .replace(/create extension if not exists pgcrypto;?/gi, ''));

    assert.equal(Number(await scalar(db, `
      select count(*) from information_schema.columns
      where table_schema = 'public' and table_name = 'mo_orders'
        and column_name = 'issued_by' and data_type = 'uuid'`)), 1,
      'ο installer πρέπει να δημιουργεί τη στήλη mo_orders.issued_by');

    assert.match(await scalar(db, `
      select pg_get_constraintdef(oid) from pg_constraint
      where conrelid = 'public.mo_orders'::regclass and conname = 'mo_orders_status_check'`),
      /issued/, 'το CHECK του mo_orders.status πρέπει να δέχεται την κατάσταση issued');

    const actionCheck = await scalar(db, `
      select pg_get_constraintdef(oid) from pg_constraint
      where conrelid = 'public.saved_versions'::regclass
        and conname = 'saved_versions_action_check'`);
    for (const action of ['copy', 'import', 'cancel_lock']) {
      assert.match(actionCheck, new RegExp(action),
        `το CHECK του saved_versions.action πρέπει να δέχεται ${action}`);
    }
  } finally {
    await db.close();
  }
});
