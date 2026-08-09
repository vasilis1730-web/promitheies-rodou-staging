import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID='11111111-1111-1111-1111-111111111111';
const TARGET='202608090003_v36_6_5_contract_pricing.sql';
const FOLLOWUP='202608090004_v36_6_5_pricing_rpc_immutable_fix.sql';
const migrationsDir=fileURLToPath(new URL('../supabase/migrations/',import.meta.url));
const read=relative=>fs.readFileSync(new URL(relative,import.meta.url),'utf8');
const migrationNames=()=>fs.readdirSync(migrationsDir).filter(x=>/^\d+.*\.sql$/i.test(x)).sort((a,b)=>a.localeCompare(b,'en'));
async function scalar(db,sql,params=[]){const r=await db.query(sql,params);const row=r.rows[0]||{};return row[Object.keys(row)[0]];}

async function installThroughV3664(){
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

  for(const name of migrationNames()){
    if(name===TARGET) break;
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
    values(2026,'TEST/2026',date '2026-08-01','TEST-ADA',30000,true,$1,$1) returning id`,[ADMIN_ID]);
  const names={1:'Ρόδου',2:'Ιαλυσού – Καλλιθέας – Αφάντου',3:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',4:'Πεταλουδών – Καμείρου – Ατταβύρου'};
  const gids={};
  for(const n of [1,2,3,4])gids[n]=await scalar(db,`insert into public.award_groups(configuration_id,group_no,name) values($1,$2,$3) returning id`,[configId,n,names[n]]);
  for(const r of rows)await db.query(`insert into public.award_group_memberships(configuration_id,award_group_id,municipal_unit_id) values($1,$2,$3)`,[configId,gids[Number(r.group_no)],Number(r.id)]);
  return Number(rows.find(r=>Number(r.group_no)===1).id);
}

test('populated v36.6.4 -> v36.6.5 backfill περνά με υπάρχουσα immutable σύμβαση και επαναφέρει τους guards',async()=>{
  const db=await installThroughV3664();
  try{
    assert.equal(await scalar(db,`select public.app_schema_version()`),'36.6.4');
    const unitId=await activateGroups(db);
    const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
    const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
    const payload=JSON.stringify([{material_id:String(materialId),quantity:10,unit_price:5,comments:null}]);
    const lock=await scalar(db,`select public.lock_study_atomic(null,$1,$2,2026,'POPULATED UPGRADE',null,null,$3::jsonb)`,[unitId,groupId,payload]);
    const supplierId=await scalar(db,`insert into public.mo_suppliers(name,created_by) values('Legacy supplier',$1) returning id`,[ADMIN_ID]);
    const oldContract=await scalar(db,`select public.save_contract_atomic(null,$1::text,$2::text,'Legacy contract',null,null,date '2026-08-01',date '2026-08-31',24)`,[lock.study_id,String(supplierId)]);
    const contractId=oldContract.contract_id;

    assert.equal(Number(await scalar(db,`select total_amount from public.mo_contracts where id=$1`,[contractId])),50);
    assert.equal(await scalar(db,`select exists(select 1 from information_schema.columns where table_schema='public' and table_name='mo_contracts' and column_name='estimated_amount')`),false);
    await assert.rejects(db.query(`update public.mo_contracts set total_amount=49 where id=$1`,[contractId]),/αμετάβλητα|αμετάβλητο/i);

    await db.exec(fs.readFileSync(path.join(migrationsDir,TARGET),'utf8'));
    await db.exec(fs.readFileSync(path.join(migrationsDir,FOLLOWUP),'utf8'));

    assert.equal(await scalar(db,`select public.app_schema_version()`),'36.6.5');
    const c=(await db.query(`select total_amount,estimated_amount,pricing_mode,discount_pct from public.mo_contracts where id=$1`,[contractId])).rows[0];
    assert.equal(Number(c.total_amount),50);
    assert.equal(Number(c.estimated_amount),50);
    assert.equal(c.pricing_mode,'study');
    assert.equal(Number(c.discount_pct),0);

    const ci=(await db.query(`select unit_price,estimated_unit_price from public.mo_contract_items where contract_id=$1 order by id limit 1`,[contractId])).rows[0];
    assert.equal(Number(ci.unit_price),5);
    assert.equal(Number(ci.estimated_unit_price),5);

    for(const triggerName of ['trg_mo_contracts_immutable','trg_mo_contract_items_immutable']){
      assert.equal(await scalar(db,`select exists(select 1 from pg_trigger where tgname=$1 and not tgisinternal and tgenabled<>'D')`,[triggerName]),true,`${triggerName} δεν επανενεργοποιήθηκε`);
    }
    await assert.rejects(db.query(`update public.mo_contracts set total_amount=49 where id=$1`,[contractId]),/αμετάβλητα|αμετάβλητο/i);
  }finally{await db.close();}
});
