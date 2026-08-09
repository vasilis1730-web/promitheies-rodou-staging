import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID='11111111-1111-1111-1111-111111111111';
const migrationsDir=fileURLToPath(new URL('../supabase/migrations/',import.meta.url));
const read=relative=>fs.readFileSync(new URL(relative,import.meta.url),'utf8');
const migrations=()=>fs.readdirSync(migrationsDir).filter(x=>/^\d+.*\.sql$/i.test(x) && x.localeCompare('202608090005_v36_6_6_resilience.sql','en')<0).sort((a,b)=>a.localeCompare(b,'en'));
async function scalar(db,sql,params=[]){const r=await db.query(sql,params);const row=r.rows[0]||{};return row[Object.keys(row)[0]];}

async function install(){
  const db=new PGlite();
  await db.exec(`
    create role anon nologin; create role authenticated nologin; create role service_role nologin;
    create schema auth;
    create table auth.users(id uuid primary key default gen_random_uuid(),email text,raw_user_meta_data jsonb default '{}'::jsonb,encrypted_password text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.uid',true),'')::uuid$$;
    create function auth.jwt() returns jsonb language sql stable as $$select '{}'::jsonb$$;
    create schema if not exists extensions;
  `);
  await db.exec(read('../supabase/00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql').replace(/create extension if not exists pgcrypto;?/gi,''));
  for(const name of migrations()){
    const sql=fs.readFileSync(path.join(migrationsDir,name),'utf8').replace(/create extension if not exists pgcrypto;?/gi,'');
    try{await db.exec(sql);}catch(e){try{await db.exec('rollback');}catch{};throw new Error(`Migration ${name} failed: ${e?.message||e}`);}
  }
  await db.exec(`
    insert into auth.users(id,email) values ('${ADMIN_ID}','admin@rhodes.gr');
    insert into public.profiles(id,role,municipal_unit_id,full_name,email,is_active)
    values ('${ADMIN_ID}','admin',null,'Admin','admin@rhodes.gr',true)
    on conflict(id) do nothing;
    create or replace function auth.uid() returns uuid language sql stable as $$select '${ADMIN_ID}'::uuid$$;
    create or replace function public.app_user_is_active() returns boolean language sql stable as $$select true$$;
    create or replace function public.app_current_role() returns text language sql stable as $$select 'admin'::text$$;
    create or replace function public.app_current_unit_id() returns bigint language sql stable as $$select null::bigint$$;
    create or replace function public.app_is_admin() returns boolean language sql stable as $$select true$$;
    create or replace function public.app_can_supervise() returns boolean language sql stable as $$select true$$;
    create or replace function public.app_can_read_unit(p_municipal_unit_id bigint) returns boolean language sql stable as $$select true$$;
    create or replace function public.app_can_write_unit(p_municipal_unit_id bigint) returns boolean language sql stable as $$select true$$;
  `);
  return db;
}

async function activateGroups(db){
  const rows=(await db.query(`select id::bigint id,public.app_rhodes_award_group_no(id::bigint)::int group_no from public.municipal_units where id<>11 order by id`)).rows;
  const configId=await scalar(db,`
    insert into public.award_group_configurations(budget_year,decision_number,decision_date,decision_ada,direct_award_cap,is_active,created_by,updated_by)
    values(2026,'TEST/2026',date '2026-08-04','ΡΤΗΦΓΗΓ',30000,true,$1,$1) returning id`,[ADMIN_ID]);
  const names={1:'Ρόδου',2:'Ιαλυσού – Καλλιθέας – Αφάντου',3:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',4:'Πεταλουδών – Καμείρου – Ατταβύρου'};
  const gids={};
  for(const n of [1,2,3,4])gids[n]=await scalar(db,`insert into public.award_groups(configuration_id,group_no,name) values($1,$2,$3) returning id`,[configId,n,names[n]]);
  for(const r of rows)await db.query(`insert into public.award_group_memberships(configuration_id,award_group_id,municipal_unit_id) values($1,$2,$3)`,[configId,gids[Number(r.group_no)],Number(r.id)]);
  return {configId,unitId:Number(rows.find(r=>Number(r.group_no)===1).id)};
}

function payload(materialId,qty=10,price=5){
  return JSON.stringify([{material_id:String(materialId),quantity:qty,unit_price:price,comments:null}]);
}
function orderPayload(item){
  return JSON.stringify([{contract_item_id:String(item.id),quantity:1,unit_price:Number(item.unit_price),description:item.description,unit:item.unit}]);
}

const zeroTables=[
  'unit_requests','request_lines','saved_versions','export_jobs','locked_studies','study_templates',
  'mo_contracts','mo_contract_items','mo_orders','mo_order_items','mo_suppliers','mo_receivers',
  'mo_projects','mo_counters','app_excel_import_tokens','tender_overrides','app_audit_log'
];

test('one-time GO-LIVE RESET μηδενίζει όλες τις δοκιμές, κρατά master data και την Απόφαση 195/2026',async()=>{
  const db=await install();
  try{
    const {configId,unitId}=await activateGroups(db);
    const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
    const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
    const materialsBefore=Number(await scalar(db,`select count(*) from public.materials where is_active`));
    const profilesBefore=Number(await scalar(db,`select count(*) from public.profiles where is_active`));

    const saved=await scalar(db,`select public.save_unit_request_atomic(null,$1,$2,2026,'GO-LIVE TEST','save',$3::jsonb)`,[unitId,groupId,payload(materialId)]);
    const lock=await scalar(db,`select public.lock_study_atomic($1::text,$2,$3,2026,'GO-LIVE TEST',null,null,$4::jsonb)`,[saved.request_id,unitId,groupId,payload(materialId)]);
    const supplierId=await scalar(db,`insert into public.mo_suppliers(name,created_by) values('TEST SUPPLIER',$1) returning id`,[ADMIN_ID]);
    const receiverId=await scalar(db,`insert into public.mo_receivers(name,created_by) values('TEST RECEIVER',$1) returning id`,[ADMIN_ID]);
    await db.query(`insert into public.mo_projects(name,created_by) values('TEST PROJECT',$1)`,[ADMIN_ID]);

    const contract=await scalar(db,`select public.save_contract_pricing_atomic(null,$1::text,$2::text,'TEST CONTRACT',null,null,date '2026-08-01',date '2026-08-31',24,'discount',10,null)`,[lock.study_id,String(supplierId)]);
    const item=(await db.query(`select * from public.mo_contract_items where contract_id=$1 order by id limit 1`,[contract.contract_id])).rows[0];
    const issued=await scalar(db,`select public.save_order_atomic(null,$1::text,date '2026-08-15',$2::text,'TEST',null,24,$3::jsonb,true)`,[lock.study_id,String(receiverId),orderPayload(item)]);
    assert.equal(issued.status,'issued');

    await scalar(db,`select public.save_locked_study_as_template_atomic($1::text,'TEST TEMPLATE','pre-go-live')`,[lock.study_id]);
    await db.query(`insert into public.export_jobs(request_id,municipal_unit_id,group_id,export_type,scope,file_name,payload,created_by) values($1,$2,$3,'excel','unit_group','test.xlsx','{}'::jsonb,$4)`,[saved.request_id,unitId,groupId,ADMIN_ID]);
    await db.query(`insert into public.tender_overrides(id,data,updated_by) values('TEST:OVERRIDE','{"test":true}'::jsonb,$1)`,[ADMIN_ID]);
    const catalogCount=Number(await scalar(db,`select count(*) from public.materials where group_id=$1 and is_active`,[groupId]));
    await scalar(db,`select public.issue_excel_export_token($1,$2,2026,$3)`,[unitId,groupId,catalogCount]);

    assert.ok(Number(await scalar(db,`select count(*) from public.locked_studies`))>0);
    assert.ok(Number(await scalar(db,`select count(*) from public.mo_contracts`))>0);
    assert.ok(Number(await scalar(db,`select count(*) from public.mo_orders`))>0);
    assert.ok(Number(await scalar(db,`select count(*) from public.app_audit_log`))>0);

    await db.exec(read('../supabase/111_GO_LIVE_RESET_V36_6_5.sql'));

    for(const table of zeroTables){
      assert.equal(Number(await scalar(db,`select count(*) from public.${table}`)),0,`${table} δεν μηδενίστηκε`);
    }

    assert.equal(Number(await scalar(db,`select count(*) from public.materials where is_active`)),materialsBefore);
    assert.equal(Number(await scalar(db,`select count(*) from public.profiles where is_active`)),profilesBefore);
    assert.equal(Number(await scalar(db,`select count(*) from public.award_groups where configuration_id=$1`,[configId])),4);
    assert.equal(Number(await scalar(db,`select count(*) from public.award_group_memberships where configuration_id=$1`,[configId])),10);

    const decision=(await db.query(`select decision_number,decision_date::text,decision_ada,direct_award_cap,is_active from public.award_group_configurations where budget_year=2026`)).rows[0];
    assert.equal(decision.decision_number,'195/2026');
    assert.equal(decision.decision_date,'2026-07-21');
    assert.equal(decision.decision_ada,'9ΒΜΣΩ1Ρ-ΣΝ3');
    assert.equal(Number(decision.direct_award_cap),30000);
    assert.equal(decision.is_active,true);
    assert.equal(await scalar(db,`select public.app_schema_version()`),'36.6.5');

    for(const triggerName of ['trg_locked_studies_immutable','trg_mo_orders_immutable','trg_mo_contract_items_immutable']){
      assert.equal(await scalar(db,`select exists(select 1 from pg_trigger where tgname=$1 and not tgisinternal and tgenabled<>'D')`,[triggerName]),true,`${triggerName} δεν παρέμεινε ενεργό`);
    }
  }finally{await db.close();}
});
