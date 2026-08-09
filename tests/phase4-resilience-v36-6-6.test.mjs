import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID='11111111-1111-1111-1111-111111111111';
const USER2_ID='22222222-2222-2222-2222-222222222222';
const migrationsDir=fileURLToPath(new URL('../supabase/migrations/',import.meta.url));
const read=relative=>fs.readFileSync(new URL(relative,import.meta.url),'utf8');
const migrations=()=>fs.readdirSync(migrationsDir).filter(x=>/^\d+.*\.sql$/i.test(x)).sort((a,b)=>a.localeCompare(b,'en'));
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
    insert into auth.users(id,email) values ('${ADMIN_ID}','admin@rhodes.gr'),('${USER2_ID}','user2@rhodes.gr');
    insert into public.profiles(id,role,municipal_unit_id,full_name,email,is_active)
    values ('${ADMIN_ID}','admin',null,'Admin','admin@rhodes.gr',true),
           ('${USER2_ID}','unit_user',1,'User 2','user2@rhodes.gr',true)
    on conflict(id) do nothing;
    create or replace function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('app.uid',true),'')::uuid$$;
    create or replace function public.app_user_is_active() returns boolean language sql stable as $$select true$$;
    create or replace function public.app_current_role() returns text language sql stable as $$select case when auth.uid()='${ADMIN_ID}'::uuid then 'admin' else 'unit_user' end$$;
    create or replace function public.app_current_unit_id() returns bigint language sql stable as $$select case when auth.uid()='${ADMIN_ID}'::uuid then null::bigint else 1::bigint end$$;
    create or replace function public.app_is_admin() returns boolean language sql stable as $$select auth.uid()='${ADMIN_ID}'::uuid$$;
    create or replace function public.app_can_supervise() returns boolean language sql stable as $$select true$$;
    create or replace function public.app_can_read_unit(p_municipal_unit_id bigint) returns boolean language sql stable as $$select true$$;
    create or replace function public.app_can_write_unit(p_municipal_unit_id bigint) returns boolean language sql stable as $$select true$$;
  `);
  await setUser(db,ADMIN_ID);
  return db;
}
async function setUser(db,id){await db.exec(`select set_config('app.uid','${id}',false)`);}

async function activateGroups(db){
  const rows=(await db.query(`select id::bigint id,public.app_rhodes_award_group_no(id::bigint)::int group_no from public.municipal_units where id<>11 order by id`)).rows;
  const configId=await scalar(db,`insert into public.award_group_configurations(budget_year,decision_number,decision_date,decision_ada,direct_award_cap,is_active,created_by,updated_by) values(2026,'195/2026',date '2026-07-21','9ΒΜΣΩ1Ρ-ΣΝ3',30000,true,$1,$1) returning id`,[ADMIN_ID]);
  const names={1:'Ρόδου',2:'Ιαλυσού – Καλλιθέας – Αφάντου',3:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',4:'Πεταλουδών – Καμείρου – Ατταβύρου'};
  const gids={};
  for(const n of [1,2,3,4])gids[n]=await scalar(db,`insert into public.award_groups(configuration_id,group_no,name) values($1,$2,$3) returning id`,[configId,n,names[n]]);
  for(const r of rows)await db.query(`insert into public.award_group_memberships(configuration_id,award_group_id,municipal_unit_id) values($1,$2,$3)`,[configId,gids[Number(r.group_no)],Number(r.id)]);
  return {configId,unitId:Number(rows.find(r=>Number(r.group_no)===1).id)};
}

async function context(db){
  const {unitId}=await activateGroups(db);
  const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
  const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
  return {unitId,groupId,materialId};
}
function lines(materialId,qty=2,price=5){return JSON.stringify([{material_id:String(materialId),quantity:qty,unit_price:price,comments:null}]);}
function op(n){return `aaaaaaaa-aaaa-4aaa-8aaa-${String(n).padStart(12,'0')}`;}

async function saveReq(db,x,{operation=op(1),expected=0,requestId=null,qty=2,price=5}={}){
  return scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,$2::bigint,$3::text,$4,$5,2026,'Phase4','save',$6::jsonb)`,[operation,expected,requestId,x.unitId,x.groupId,lines(x.materialId,qty,price)]);
}
async function lockStudy(db,x,{operation=op(2),expected=0,requestId=null,qty=2,price=5}={}){
  return scalar(db,`select public.lock_study_resilient_atomic($1::uuid,$2::bigint,$3::text,$4,$5,2026,'Phase4',null,null,$6::jsonb)`,[operation,expected,requestId,x.unitId,x.groupId,lines(x.materialId,qty,price)]);
}

async function prepareContract(db){
  const x=await context(db);
  const saved=await saveReq(db,x,{operation:op(10)});
  const locked=await lockStudy(db,x,{operation:op(11),expected:Number(saved.revision),requestId:saved.request_id});
  const supplierId=await scalar(db,`insert into public.mo_suppliers(name,created_by) values('Supplier',$1) returning id`,[ADMIN_ID]);
  const receiverId=await scalar(db,`insert into public.mo_receivers(name,created_by) values('Receiver',$1) returning id`,[ADMIN_ID]);
  const contract=await scalar(db,`select public.save_contract_pricing_resilient_atomic($1::uuid,null,$2::text,$3::text,'Contract',null,null,date '2026-08-01',date '2026-08-31',24,'study',0,null)`,[op(12),locked.study_id,String(supplierId)]);
  const item=(await db.query(`select * from public.mo_contract_items where contract_id=$1 order by id limit 1`,[contract.contract_id])).rows[0];
  return {...x,saved,locked,supplierId,receiverId,contract,item};
}
function orderItems(item,qty=1){return JSON.stringify([{contract_item_id:String(item.id),quantity:qty,unit_price:Number(item.unit_price),description:item.description,unit:item.unit}]);}


test('clean install φτάνει σε 36.6.6 και εκθέτει μόνο resilient critical entry points',async()=>{
  const db=await install();
  try{
    assert.equal(await scalar(db,`select public.app_schema_version()`),'36.6.6');
    assert.equal(await scalar(db,`select exists(select 1 from information_schema.columns where table_schema='public' and table_name='unit_requests' and column_name='revision')`),true);
    assert.equal(await scalar(db,`select to_regclass('public.app_operation_idempotency') is not null`),true);
    for(const sig of [
      'public.save_unit_request_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,jsonb)',
      'public.lock_study_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,text,jsonb)',
      'public.save_contract_pricing_resilient_atomic(uuid,text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)',
      'public.save_order_resilient_atomic(uuid,text,text,date,text,text,text,numeric,jsonb,boolean)',
      'public.secure_import_catalog_request_resilient_atomic(uuid,bigint,uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)'
    ]) assert.equal(await scalar(db,`select to_regprocedure($1) is not null`,[sig]),true,sig);
  }finally{await db.close();}
});

test('ίδιο operation_id σε διπλή αποθήκευση δεν δημιουργεί δεύτερη έκδοση ούτε αυξάνει δεύτερη φορά το revision',async()=>{
  const db=await install();
  try{
    const x=await context(db);
    const a=await saveReq(db,x,{operation:op(20)});
    const b=await saveReq(db,x,{operation:op(20)});
    assert.equal(a.request_id,b.request_id);
    assert.equal(Number(a.revision),1);
    assert.equal(Number(b.revision),1);
    assert.equal(Number(await scalar(db,`select revision from public.unit_requests where id=$1`,[a.request_id])),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.saved_versions where request_id=$1 and action='save'`,[a.request_id])),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.app_operation_idempotency where operation_id=$1::uuid`,[op(20)])),1);
  }finally{await db.close();}
});

test('stale revision δεύτερου χρήστη απορρίπτεται αντί για silent last-writer-wins',async()=>{
  const db=await install();
  try{
    const x=await context(db);
    const first=await saveReq(db,x,{operation:op(30),qty:2});
    await setUser(db,USER2_ID);
    await assert.rejects(saveReq(db,x,{operation:op(31),expected:0,requestId:first.request_id,qty:9}),/άλλαξε από άλλο χρήστη/i);
    assert.equal(Number(await scalar(db,`select quantity from public.request_lines where request_id=$1`,[first.request_id])),2);
    await setUser(db,ADMIN_ID);
    const second=await saveReq(db,x,{operation:op(32),expected:1,requestId:first.request_id,qty:3});
    assert.equal(Number(second.revision),2);
    assert.equal(Number(await scalar(db,`select quantity from public.request_lines where request_id=$1`,[first.request_id])),3);
  }finally{await db.close();}
});

test('διπλό κλείδωμα με ίδιο operation_id επιστρέφει την ίδια μελέτη και δημιουργεί μία μόνο εγγραφή',async()=>{
  const db=await install();
  try{
    const x=await context(db);
    const saved=await saveReq(db,x,{operation:op(40)});
    const a=await lockStudy(db,x,{operation:op(41),expected:1,requestId:saved.request_id});
    const b=await lockStudy(db,x,{operation:op(41),expected:1,requestId:saved.request_id});
    assert.equal(a.study_id,b.study_id);
    assert.equal(Number(await scalar(db,`select count(*) from public.locked_studies where id=$1`,[a.study_id])),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.locked_studies where source_request_id=$1`,[saved.request_id])),1);
  }finally{await db.close();}
});

test('διπλή έκδοση δελτίου με ίδιο operation_id δεν καταναλώνει δεύτερο αριθμό ούτε δημιουργεί δεύτερο δελτίο',async()=>{
  const db=await install();
  try{
    const x=await prepareContract(db);
    const args=[op(50),x.locked.study_id,String(x.receiverId),orderItems(x.item)];
    const a=await scalar(db,`select public.save_order_resilient_atomic($1::uuid,null,$2::text,date '2026-08-15',$3::text,'Test',null,24,$4::jsonb,true)`,args);
    const b=await scalar(db,`select public.save_order_resilient_atomic($1::uuid,null,$2::text,date '2026-08-15',$3::text,'Test',null,24,$4::jsonb,true)`,args);
    assert.equal(a.order_id,b.order_id);
    assert.equal(a.order_no,b.order_no);
    assert.equal(Number(await scalar(db,`select count(*) from public.mo_orders where study_id=$1`,[x.locked.study_id])),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.mo_order_number_counters`)),1);
    assert.equal(Number(await scalar(db,`select max(last_value) from public.mo_order_number_counters`)),1);
  }finally{await db.close();}
});

test('ίδιο operation_id με διαφορετικό payload απορρίπτεται και δεν μεταλλάσσει δεδομένα',async()=>{
  const db=await install();
  try{
    const x=await context(db);
    const a=await saveReq(db,x,{operation:op(60),qty:2});
    await assert.rejects(saveReq(db,x,{operation:op(60),expected:0,requestId:null,qty:8}),/ίδιο operation_id.*διαφορετικ/i);
    assert.equal(Number(await scalar(db,`select quantity from public.request_lines where request_id=$1`,[a.request_id])),2);
  }finally{await db.close();}
});

test('σφάλμα μέσα σε resilient order κάνει rollback και δεν αφήνει ούτε order ούτε idempotency residue',async()=>{
  const db=await install();
  try{
    const x=await prepareContract(db);
    const invalid=JSON.stringify([
      {contract_item_id:String(x.item.id),quantity:1,unit_price:Number(x.item.unit_price),description:x.item.description,unit:x.item.unit},
      {contract_item_id:'999999999',quantity:1,unit_price:1,description:'Invalid',unit:'τεμ.'}
    ]);
    await assert.rejects(
      db.query(`select public.save_order_resilient_atomic($1::uuid,null,$2::text,date '2026-08-15',$3::text,'Test',null,24,$4::jsonb,true)`,[op(70),x.locked.study_id,String(x.receiverId),invalid]),
      /δεν ανήκει|δεν βρέθηκε|συμβατικ/i
    );
    assert.equal(Number(await scalar(db,`select count(*) from public.mo_orders where study_id=$1`,[x.locked.study_id])),0);
    assert.equal(Number(await scalar(db,`select count(*) from public.app_operation_idempotency where operation_id=$1::uuid`,[op(70)])),0);
  }finally{await db.close();}
});

test('Excel import είναι idempotent: retry ίδιας ενέργειας δεν επαναχρησιμοποιεί token ούτε διπλασιάζει request/version',async()=>{
  const db=await install();
  try{
    const x=await context(db);
    const count=Number(await scalar(db,`select count(*) from public.materials where group_id=$1 and is_active`,[x.groupId]));
    const ticket=await scalar(db,`select public.issue_excel_export_token($1,$2,2026,$3)`,[x.unitId,x.groupId,count]);
    const payload=lines(x.materialId,4,5);
    const args=[op(80),ticket.token,x.unitId,x.groupId,payload];
    const a=await scalar(db,`select public.secure_import_catalog_request_resilient_atomic($1::uuid,0,$2::uuid,null,$3,$4,2026,'Excel','[]'::jsonb,'[]'::jsonb,$5::jsonb)`,args);
    const b=await scalar(db,`select public.secure_import_catalog_request_resilient_atomic($1::uuid,0,$2::uuid,null,$3,$4,2026,'Excel','[]'::jsonb,'[]'::jsonb,$5::jsonb)`,args);
    assert.equal(a.request_id,b.request_id);
    assert.equal(Number(a.revision),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.unit_requests where id=$1`,[a.request_id])),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.app_excel_import_tokens where token=$1::uuid and used_at is not null`,[ticket.token])),1);
    assert.equal(Number(await scalar(db,`select revision from public.unit_requests where id=$1`,[a.request_id])),1);
  }finally{await db.close();}
});
