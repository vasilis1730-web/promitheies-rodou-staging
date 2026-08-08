import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { PGlite } from '@electric-sql/pglite';

const migration = fs.readFileSync(
  new URL('../supabase/migrations/202608060004_admin_study_templates_and_purge.sql', import.meta.url),
  'utf8'
);
const issueHotfix = fs.readFileSync(
  new URL('../supabase/migrations/202608070001_fix_order_issue_and_purge_audit.sql', import.meta.url),
  'utf8'
);

const ADMIN_ID = '00000000-0000-0000-0000-000000000001';
const STUDY_ID = '10000000-0000-0000-0000-000000000001';
const REQUEST_ID = '20000000-0000-0000-0000-000000000001';
const MATERIAL_ID = '30000000-0000-0000-0000-000000000001';
const SUPPLIER_ID = '40000000-0000-0000-0000-000000000001';
const CONTRACT_ID = '50000000-0000-0000-0000-000000000001';
const CONTRACT_ITEM_ID = '60000000-0000-0000-0000-000000000001';
const ORDER_ID = '70000000-0000-0000-0000-000000000001';

async function scalar(db, sql) {
  const result = await db.query(sql);
  const row = result.rows[0] || {};
  return row[Object.keys(row)[0]];
}

async function createDb() {
  const db = new PGlite();
  await db.exec(`
    create role anon nologin;
    create role authenticated nologin;
    create schema auth;
    create table auth.users (id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
    $$;

    create table public.municipal_units (id bigint primary key, name text);
    create table public.procurement_groups (id bigint primary key, name text, domain text);
    create table public.profiles (id uuid primary key references auth.users(id), role text, municipal_unit_id bigint);
    create table public.user_app_permissions (user_id uuid primary key, can_supervise boolean default false);
    create table public.materials (
      id uuid primary key, group_id bigint references public.procurement_groups(id),
      name text, default_unit_price numeric, sort_order integer, is_active boolean default true
    );
    create table public.unit_requests (
      id uuid primary key default gen_random_uuid(), municipal_unit_id bigint references public.municipal_units(id),
      group_id bigint references public.procurement_groups(id), request_year integer, title text,
      status text default 'draft', unique(municipal_unit_id,group_id,request_year)
    );
    create table public.request_lines (
      request_id uuid references public.unit_requests(id) on delete cascade,
      material_id uuid references public.materials(id), quantity numeric, unit_price numeric,
      comments text, primary key(request_id,material_id)
    );
    create table public.saved_versions (
      id uuid primary key default gen_random_uuid(), request_id uuid references public.unit_requests(id),
      action text, snapshot jsonb, created_at timestamptz default now()
    );
    create table public.export_jobs (
      id uuid primary key default gen_random_uuid(), request_id uuid references public.unit_requests(id),
      payload jsonb
    );
    create table public.award_group_configurations (
      id bigint primary key, budget_year integer, is_active boolean
    );
    create table public.award_group_memberships (
      configuration_id bigint, municipal_unit_id bigint, award_group_id bigint
    );
    create table public.locked_studies (
      id uuid primary key default gen_random_uuid(), municipal_unit_id bigint references public.municipal_units(id),
      group_id bigint references public.procurement_groups(id), award_group_id bigint,
      request_year integer, source_request_id uuid references public.unit_requests(id), seq integer,
      label text, net_total numeric, item_count integer, lines jsonb, supplier_name text, kimdis_url text,
      record_status text default 'active', cancelled_at timestamptz, cancelled_by uuid,
      cancellation_reason text, locked_at timestamptz default now()
    );
    create table public.mo_suppliers (id uuid primary key, name text);
    create table public.mo_contracts (
      id uuid primary key, supplier_id uuid references public.mo_suppliers(id), source_study_id uuid references public.locked_studies(id),
      municipal_unit_id bigint, adam text, protocol_no text, start_date date, end_date date,
      active boolean default true, updated_at timestamptz default now(), updated_by uuid
    );
    create table public.mo_contract_items (
      id uuid primary key, contract_id uuid references public.mo_contracts(id), description text
    );
    create table public.mo_orders (
      id uuid primary key, study_id uuid references public.locked_studies(id) on delete restrict,
      contract_id uuid references public.mo_contracts(id), order_no text,
      status text default 'draft'
        check (status in ('draft','sent','received','cancelled')),
      municipal_unit_id bigint
    );
    create table public.mo_order_items (
      id uuid primary key default gen_random_uuid(), order_id uuid references public.mo_orders(id),
      contract_item_id uuid references public.mo_contract_items(id), description text
    );
    create table public.app_audit_log (
      id bigint generated by default as identity primary key, event_type text, entity_type text,
      entity_id text, municipal_unit_id bigint, before_data jsonb, after_data jsonb,
      metadata jsonb default '{}'::jsonb
    );

    create function public.app_schema_version() returns text language sql stable as $$ select '36.5.5'::text $$;
    create function public.app_is_admin() returns boolean language sql stable as $$
      select exists(select 1 from public.profiles p where p.id=auth.uid() and p.role='admin')
    $$;
    create function public.app_can_write_unit(p_unit bigint) returns boolean language sql stable as $$
      select public.app_is_admin() or exists(
        select 1 from public.profiles p where p.id=auth.uid() and p.role='unit_user' and p.municipal_unit_id=p_unit
      )
    $$;
    create function public.app_write_audit(
      p_event_type text,p_entity_type text,p_entity_id text,p_municipal_unit_id bigint,
      p_reason text,p_before_data jsonb,p_after_data jsonb,p_metadata jsonb default '{}'::jsonb
    ) returns bigint language plpgsql as $$
    declare v_id bigint;
    begin
      insert into public.app_audit_log(event_type,entity_type,entity_id,municipal_unit_id,before_data,after_data,metadata)
      values(p_event_type,p_entity_type,p_entity_id,p_municipal_unit_id,p_before_data,p_after_data,coalesce(p_metadata,'{}'))
      returning id into v_id;
      return v_id;
    end $$;
    create function public.save_unit_request_atomic(
      p_request_id text,p_municipal_unit_id bigint,p_group_id bigint,p_request_year integer,
      p_title text,p_action text,p_lines jsonb
    ) returns jsonb language plpgsql as $$
    declare v_id uuid; v_line jsonb;
    begin
      if p_request_id is not null then v_id:=p_request_id::uuid; end if;
      if v_id is null then
        insert into public.unit_requests(municipal_unit_id,group_id,request_year,title)
        values(p_municipal_unit_id,p_group_id,p_request_year,p_title)
        on conflict(municipal_unit_id,group_id,request_year) do update set title=excluded.title
        returning id into v_id;
      end if;
      delete from public.request_lines where request_id=v_id;
      for v_line in select value from jsonb_array_elements(p_lines)
      loop
        insert into public.request_lines(request_id,material_id,quantity,unit_price,comments)
        values(v_id,(v_line->>'material_id')::uuid,(v_line->>'quantity')::numeric,(v_line->>'unit_price')::numeric,v_line->>'comments');
      end loop;
      return jsonb_build_object('request_id',v_id::text);
    end $$;

    create function public.app_immutable_history_guard() returns trigger language plpgsql as $$ begin raise exception 'immutable'; end $$;
    create function public.app_locked_study_guard() returns trigger language plpgsql as $$ begin raise exception 'immutable'; end $$;
    create function public.app_order_guard() returns trigger language plpgsql as $$ begin raise exception 'immutable'; end $$;
    create function public.app_order_item_guard() returns trigger language plpgsql as $$ begin raise exception 'immutable'; end $$;
    create function public.app_contract_item_guard() returns trigger language plpgsql as $$ begin raise exception 'immutable'; end $$;
    create function public.app_contract_guard() returns trigger language plpgsql as $$ begin raise exception 'immutable'; end $$;
    create trigger trg_audit_immutable before delete on public.app_audit_log for each row execute function public.app_immutable_history_guard();
    create trigger trg_versions_immutable before delete on public.saved_versions for each row execute function public.app_immutable_history_guard();
    create trigger trg_study_immutable before update or delete on public.locked_studies for each row execute function public.app_locked_study_guard();
    create trigger trg_order_immutable before update or delete on public.mo_orders for each row execute function public.app_order_guard();
    create trigger trg_order_items_immutable before update or delete on public.mo_order_items for each row execute function public.app_order_item_guard();
    create trigger trg_contract_immutable before update or delete on public.mo_contracts for each row execute function public.app_contract_guard();
    create trigger trg_contract_items_immutable before update or delete on public.mo_contract_items for each row execute function public.app_contract_item_guard();

    insert into auth.users(id) values ('${ADMIN_ID}');
    insert into public.profiles(id,role,municipal_unit_id) values ('${ADMIN_ID}','admin',null);
    select set_config('request.jwt.claim.sub','${ADMIN_ID}',false);
    insert into public.municipal_units(id,name) values (1,'ΡΟΔΟΥ');
    insert into public.procurement_groups(id,name,domain) values (10,'Ηλεκτρολογικά','procurement');
    insert into public.materials(id,group_id,name,default_unit_price,sort_order,is_active)
    values ('${MATERIAL_ID}',10,'Υλικό προτύπου',25,1,true);
  `);
  return db;
}

test('η migration είναι επαναλήψιμη, δημιουργεί πρότυπο και το φορτώνει ως κανονικό πρόχειρο', async () => {
  const db = await createDb();
  try {
    await db.exec(migration);
    await db.exec(migration);
    await db.exec(issueHotfix);
    await db.exec(issueHotfix);
    assert.equal(await scalar(db, `select public.app_schema_version()`), '36.6.1');

    await db.exec(`
      insert into public.unit_requests(id,municipal_unit_id,group_id,request_year,title)
      values ('${REQUEST_ID}',1,10,2026,'Πρόχειρο');
      insert into public.locked_studies(
        id,municipal_unit_id,group_id,request_year,source_request_id,seq,label,net_total,item_count,lines,record_status
      ) values (
        '${STUDY_ID}',1,10,2026,'${REQUEST_ID}',1,'Δοκιμή',50,1,
        jsonb_build_array(jsonb_build_object(
          'material_id','${MATERIAL_ID}','name','Υλικό προτύπου','quantity',2,'unit_price',25,'subtotal',50
        )),'active'
      );
    `);

    const saved = (await db.query(`
      select public.save_locked_study_as_template_atomic('${STUDY_ID}','Βασικό πρότυπο','Δοκιμή') as result
    `)).rows[0].result;
    assert.equal(saved.name, 'Βασικό πρότυπο');
    const templateId = saved.template_id;

    const loaded = (await db.query(`
      select public.load_study_template_atomic('${templateId}',1,10,2027) as result
    `)).rows[0].result;
    assert.equal(Number(loaded.loaded_lines), 1);
    assert.equal(Number(loaded.skipped_lines), 0);
    assert.equal(Number(await scalar(db, `
      select quantity from public.request_lines l
      join public.unit_requests r on r.id=l.request_id
      where r.request_year=2027
    `)), 2);
  } finally {
    await db.close();
  }
});

test('μόνο admin κάνει πλήρη διαγραφή και η συναλλαγή αφαιρεί όλες τις συνδέσεις αλλά διατηρεί το πρότυπο', async () => {
  const db = await createDb();
  try {
    await db.exec(migration);
    await db.exec(issueHotfix);
    await db.exec(`
      insert into public.unit_requests(id,municipal_unit_id,group_id,request_year,title)
      values ('${REQUEST_ID}',1,10,2026,'Πρόχειρο');
      insert into public.locked_studies(
        id,municipal_unit_id,group_id,request_year,source_request_id,seq,label,net_total,item_count,lines,record_status
      ) values (
        '${STUDY_ID}',1,10,2026,'${REQUEST_ID}',1,'Δοκιμή',50,1,
        jsonb_build_array(jsonb_build_object(
          'material_id','${MATERIAL_ID}','name','Υλικό προτύπου','quantity',2,'unit_price',25,'subtotal',50
        )),'active'
      );
      insert into public.saved_versions(request_id,action,snapshot)
      values ('${REQUEST_ID}','lock',jsonb_build_object('locked_study_id','${STUDY_ID}'));
      insert into public.export_jobs(request_id,payload)
      values ('${REQUEST_ID}',jsonb_build_object('study_id','${STUDY_ID}'));
      insert into public.app_audit_log(event_type,entity_type,entity_id,metadata)
      values ('study_locked','locked_studies','${STUDY_ID}',jsonb_build_object('study_id','${STUDY_ID}'));
      insert into public.mo_suppliers(id,name) values ('${SUPPLIER_ID}','Ανάδοχος');
      insert into public.mo_contracts(id,supplier_id,source_study_id,municipal_unit_id)
      values ('${CONTRACT_ID}','${SUPPLIER_ID}','${STUDY_ID}',1);
      insert into public.mo_contract_items(id,contract_id,description)
      values ('${CONTRACT_ITEM_ID}','${CONTRACT_ID}','Συμβατικό είδος');
      insert into public.mo_orders(id,study_id,contract_id,status,municipal_unit_id)
      values ('${ORDER_ID}','${STUDY_ID}','${CONTRACT_ID}','received',1);
      insert into public.mo_order_items(order_id,contract_item_id,description)
      values ('${ORDER_ID}','${CONTRACT_ITEM_ID}','Γραμμή δελτίου');
    `);

    const template = (await db.query(`
      select public.save_locked_study_as_template_atomic('${STUDY_ID}','Πρότυπο πριν τη διαγραφή',null) as result
    `)).rows[0].result;

    await db.exec(`update public.profiles set role='viewer' where id='${ADMIN_ID}'`);
    await assert.rejects(
      db.query(`select public.admin_purge_locked_study_atomic('${STUDY_ID}','ΔΙΑΓΡΑΦΗ')`),
      /Μόνο administrator/
    );
    assert.equal(Number(await scalar(db, `select count(*) from public.locked_studies`)), 1);

    await db.exec(`update public.profiles set role='admin' where id='${ADMIN_ID}'`);
    await assert.rejects(
      db.query(`delete from public.locked_studies where id='${STUDY_ID}'`),
      /δεν διαγράφεται απευθείας/
    );
    await assert.rejects(
      db.query(`select public.admin_purge_locked_study_atomic('${STUDY_ID}','ΝΑΙ')`),
      /ΔΙΑΓΡΑΦΗ/
    );

    const purged = (await db.query(`
      select public.admin_purge_locked_study_atomic('${STUDY_ID}','ΔΙΑΓΡΑΦΗ') as result
    `)).rows[0].result;
    assert.equal(purged.deleted, true);
    assert.equal(Number(purged.deleted_orders), 1);
    assert.equal(Number(purged.deleted_contracts), 1);
    assert.equal(Number(purged.detached_templates), 1);

    for (const table of ['locked_studies','mo_orders','mo_order_items','mo_contracts','mo_contract_items','saved_versions','export_jobs']) {
      assert.equal(Number(await scalar(db, `select count(*) from public.${table}`)), 0, table);
    }
    // v36.6.1: το αμετάβλητο ιστορικό ΔΕΝ καθαρίζεται πλέον. Η ίδια η πλήρης
    // διαγραφή καταγράφεται, ώστε καμία μελέτη να μη χάνεται χωρίς ίχνος.
    assert.ok(Number(await scalar(db, `select count(*) from public.app_audit_log where entity_id='${STUDY_ID}'`)) > 0,
      'οι εγγραφές ιστορικού της μελέτης πρέπει να διατηρούνται');
    assert.equal(Number(await scalar(db, `select count(*) from public.app_audit_log where event_type='study_purged' and entity_id='${STUDY_ID}'`)), 1,
      'η πλήρης διαγραφή πρέπει να καταγράφεται ως study_purged');
    assert.equal(Number(await scalar(db, `select count(*) from public.app_audit_log where event_type='study_purged' and (metadata->>'study_seq')::int = 1`)), 1);
    assert.equal(Number(await scalar(db, `select count(*) from public.study_templates where id='${template.template_id}' and source_study_id is null`)), 1);
    assert.equal(Number(await scalar(db, `select count(*) from public.unit_requests where id='${REQUEST_ID}'`)), 1);
  } finally {
    await db.close();
  }
});
