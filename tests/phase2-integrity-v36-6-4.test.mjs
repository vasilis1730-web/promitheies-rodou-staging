import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID='11111111-1111-1111-1111-111111111111';
const UNIT_ID='22222222-2222-2222-2222-222222222222';
const migrationsDir=fileURLToPath(new URL('../supabase/migrations/',import.meta.url));

function read(relative){return fs.readFileSync(new URL(relative,import.meta.url),'utf8');}
function migrations(){return fs.readdirSync(migrationsDir).filter(x=>/^\d+.*\.sql$/i.test(x)).sort((a,b)=>a.localeCompare(b,'en'));}
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
    insert into auth.users(id,email) values ('${ADMIN_ID}','admin@rhodes.gr'),('${UNIT_ID}','unit@rhodes.gr');
    insert into public.profiles(id,role,municipal_unit_id,full_name,email,is_active)
    values ('${ADMIN_ID}','admin',null,'Admin','admin@rhodes.gr',true),
           ('${UNIT_ID}','unit_user',1,'Unit','unit@rhodes.gr',true)
    on conflict(id) do nothing;
  `);
  return db;
}

async function activateGroups(db){
  await db.exec(`select set_config('app.uid','${ADMIN_ID}',false);`);
  const rows=await db.query(`select id from public.municipal_units where id<>11 order by id`);
  const ids=rows.rows.map(r=>Number(r.id));
  assert.equal(ids.length,10);
  const groups=[
    {group_no:1,name:'G1',municipal_unit_ids:[ids[0]]},
    {group_no:2,name:'G2',municipal_unit_ids:ids.slice(1,4)},
    {group_no:3,name:'G3',municipal_unit_ids:ids.slice(4,7)},
    {group_no:4,name:'G4',municipal_unit_ids:ids.slice(7,10)}
  ];
  await db.query(`select public.save_award_group_configuration(2026,'1/2026',current_date,'TEST',30000,$1::jsonb)`,[JSON.stringify(groups)]);
  return ids[0];
}

async function prepareContract(db){
  const unitId=await activateGroups(db);
  const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
  const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
  const lock=await scalar(db,`select public.lock_study_atomic(null,$1,$2,2026,'Phase2',null,null,jsonb_build_array(jsonb_build_object('material_id',$3::text,'quantity',10,'unit_price',5,'comments',null)))`,[unitId,groupId,materialId]);
  const supplierId=await scalar(db,`insert into public.mo_suppliers(name,created_by) values('Supplier',$1) returning id`,[ADMIN_ID]);
  const receiverId=await scalar(db,`insert into public.mo_receivers(name,created_by) values('Receiver',$1) returning id`,[ADMIN_ID]);
  const contract=await scalar(db,`select public.save_contract_atomic(null,$1,$2,'Contract',null,null,date '2026-08-01',date '2026-08-31',24)`,[lock.study_id,supplierId]);
  const item=(await db.query(`select id,unit_price from public.mo_contract_items where contract_id=$1 order by id limit 1`,[contract.contract_id])).rows[0];
  const items=JSON.stringify([{contract_item_id:String(item.id),quantity:1,unit_price:Number(item.unit_price),description:'x',unit:'τεμ.'}]);
  return {lock,receiverId,items};
}

test('legacy import_catalog_request_atomic δεν είναι callable από authenticated ενώ το secure wrapper παραμένει API RPC',async()=>{
  const db=await install();
  try{
    assert.equal(await scalar(db,`select public.app_schema_version()`),'36.6.4');
    assert.equal(await scalar(db,`select has_function_privilege('authenticated','public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)','EXECUTE')`),false);
    assert.equal(await scalar(db,`select has_function_privilege('authenticated','public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)','EXECUTE')`),true);
  }finally{await db.close();}
});

test('δελτίο με ΦΠΑ διαφορετικό από τη σύμβαση απορρίπτεται server-side',async()=>{
  const db=await install();
  try{
    const x=await prepareContract(db);
    await assert.rejects(
      db.query(`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Αποθήκη',null,13,$3::jsonb,true)`,[x.lock.study_id,String(x.receiverId),x.items]),
      /ΦΠΑ.*δεν συμφωνεί/i
    );
  }finally{await db.close();}
});

test('έκδοση δελτίου εκτός διάρκειας σύμβασης απορρίπτεται, ενώ εντός διάρκειας επιτρέπεται',async()=>{
  const db=await install();
  try{
    const x=await prepareContract(db);
    await assert.rejects(
      db.query(`select public.save_order_atomic(null,$1,date '2026-09-01',$2,'Αποθήκη',null,24,$3::jsonb,true)`,[x.lock.study_id,String(x.receiverId),x.items]),
      /μεταγενέστερη.*λήξης/i
    );
    const ok=await scalar(db,`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Αποθήκη',null,24,$3::jsonb,true)`,[x.lock.study_id,String(x.receiverId),x.items]);
    assert.equal(ok.status,'issued');
  }finally{await db.close();}
});
