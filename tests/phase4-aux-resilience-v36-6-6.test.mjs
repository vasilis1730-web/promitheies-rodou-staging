import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID='11111111-1111-1111-1111-111111111111';
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
  const configId=await scalar(db,`insert into public.award_group_configurations(budget_year,decision_number,decision_date,decision_ada,direct_award_cap,is_active,created_by,updated_by) values(2026,'195/2026',date '2026-07-21','9ΒΜΣΩ1Ρ-ΣΝ3',30000,true,$1,$1) returning id`,[ADMIN_ID]);
  const names={1:'Ρόδου',2:'Ιαλυσού – Καλλιθέας – Αφάντου',3:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',4:'Πεταλουδών – Καμείρου – Ατταβύρου'};
  const gids={};
  for(const n of [1,2,3,4])gids[n]=await scalar(db,`insert into public.award_groups(configuration_id,group_no,name) values($1,$2,$3) returning id`,[configId,n,names[n]]);
  for(const r of rows)await db.query(`insert into public.award_group_memberships(configuration_id,award_group_id,municipal_unit_id) values($1,$2,$3)`,[configId,gids[Number(r.group_no)],Number(r.id)]);
  const group1=rows.filter(r=>Number(r.group_no)===1).map(r=>Number(r.id));
  const other=rows.find(r=>Number(r.group_no)!==1);
  return {sourceUnit:group1[0],destUnit:Number(other.id)};
}

function op(n){return `bbbbbbbb-bbbb-4bbb-8bbb-${String(n).padStart(12,'0')}`;}
function payload(materialId,qty=2){return JSON.stringify([{material_id:String(materialId),quantity:qty,unit_price:5,comments:null}]);}

async function baseContext(db){
  const {sourceUnit,destUnit}=await activateGroups(db);
  const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
  const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
  return {sourceUnit,destUnit,groupId,materialId};
}

test('όλες οι legacy critical write RPCs είναι κλειστές για authenticated',async()=>{
  const db=await install();
  try{
    const signatures=[
      'public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)',
      'public.lock_study_atomic(text,bigint,bigint,integer,text,text,text,jsonb)',
      'public.save_contract_atomic(text,text,text,text,text,text,date,date,numeric)',
      'public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)',
      'public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean)',
      'public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)',
      'public.copy_unit_request_atomic(bigint,bigint,bigint,integer,text,jsonb)',
      'public.load_study_template_atomic(text,bigint,bigint,integer)'
    ];
    for(const sig of signatures){
      assert.equal(await scalar(db,`select has_function_privilege('authenticated',$1,'EXECUTE')`,[sig]),false,sig);
    }
  }finally{await db.close();}
});

test('διπλή αντιγραφή με ίδιο operation_id εφαρμόζεται μία φορά και αυξάνει revision μία φορά',async()=>{
  const db=await install();
  try{
    const x=await baseContext(db);
    await scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,0,null,$2,$3,2026,'Source','save',$4::jsonb)`,[op(10),x.sourceUnit,x.groupId,payload(x.materialId,3)]);
    const args=[op(11),x.sourceUnit,x.destUnit,x.groupId,payload(x.materialId,3)];
    const a=await scalar(db,`select public.copy_unit_request_resilient_atomic($1::uuid,0,$2,$3,$4,2026,'Copy',$5::jsonb)`,args);
    const b=await scalar(db,`select public.copy_unit_request_resilient_atomic($1::uuid,0,$2,$3,$4,2026,'Copy',$5::jsonb)`,args);
    assert.equal(a.request_id,b.request_id);
    assert.equal(Number(a.revision),1);
    assert.equal(Number(await scalar(db,`select revision from public.unit_requests where id=$1`,[a.request_id])),1);
    assert.equal(Number(await scalar(db,`select count(*) from public.saved_versions where request_id=$1 and action='copy'`,[a.request_id])),1);
  }finally{await db.close();}
});

test('stale destination revision εμποδίζει αντιγραφή πάνω σε νεότερο πρόχειρο',async()=>{
  const db=await install();
  try{
    const x=await baseContext(db);
    await scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,0,null,$2,$3,2026,'Source','save',$4::jsonb)`,[op(20),x.sourceUnit,x.groupId,payload(x.materialId,3)]);
    const dest=await scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,0,null,$2,$3,2026,'Dest','save',$4::jsonb)`,[op(21),x.destUnit,x.groupId,payload(x.materialId,1)]);
    await scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,1,$2::text,$3,$4,2026,'Dest2','save',$5::jsonb)`,[op(22),dest.request_id,x.destUnit,x.groupId,payload(x.materialId,2)]);
    await assert.rejects(
      db.query(`select public.copy_unit_request_resilient_atomic($1::uuid,1,$2,$3,$4,2026,'Copy',$5::jsonb)`,[op(23),x.sourceUnit,x.destUnit,x.groupId,payload(x.materialId,3)]),
      /άλλαξε από άλλο χρήστη|αντιγραφή δεν εφαρμόστηκε/i
    );
    assert.equal(Number(await scalar(db,`select quantity from public.request_lines where request_id=$1`,[dest.request_id])),2);
  }finally{await db.close();}
});

test('φόρτωση προτύπου είναι idempotent και revision-aware',async()=>{
  const db=await install();
  try{
    const x=await baseContext(db);
    const saved=await scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,0,null,$2,$3,2026,'Source','save',$4::jsonb)`,[op(30),x.sourceUnit,x.groupId,payload(x.materialId,4)]);
    const locked=await scalar(db,`select public.lock_study_resilient_atomic($1::uuid,$2,$3::text,$4,$5,2026,'Locked',null,null,$6::jsonb)`,[op(31),Number(saved.revision),saved.request_id,x.sourceUnit,x.groupId,payload(x.materialId,4)]);
    const tpl=await scalar(db,`select public.save_locked_study_as_template_atomic($1::text,'Template Phase4','test')`,[locked.study_id]);

    const args=[op(32),String(tpl.template_id),x.destUnit,x.groupId];
    const a=await scalar(db,`select public.load_study_template_resilient_atomic($1::uuid,0,$2::text,$3,$4,2026)`,args);
    const b=await scalar(db,`select public.load_study_template_resilient_atomic($1::uuid,0,$2::text,$3,$4,2026)`,args);
    assert.equal(a.request_id,b.request_id);
    assert.equal(Number(a.revision),1);
    assert.equal(Number(await scalar(db,`select revision from public.unit_requests where id=$1`,[a.request_id])),1);

    await scalar(db,`select public.save_unit_request_resilient_atomic($1::uuid,1,$2::text,$3,$4,2026,'Changed','save',$5::jsonb)`,[op(33),a.request_id,x.destUnit,x.groupId,payload(x.materialId,1)]);
    await assert.rejects(
      db.query(`select public.load_study_template_resilient_atomic($1::uuid,1,$2::text,$3,$4,2026)`,[op(34),String(tpl.template_id),x.destUnit,x.groupId]),
      /άλλαξε από άλλο χρήστη|πρότυπο δεν φορτώθηκε/i
    );
  }finally{await db.close();}
});
