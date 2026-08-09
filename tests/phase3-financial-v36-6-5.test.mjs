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
    values(2026,'TEST/2026',date '2026-08-01','TEST',30000,true,$1,$1) returning id`,[ADMIN_ID]);
  const names={1:'Ρόδου',2:'Ιαλυσού – Καλλιθέας – Αφάντου',3:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',4:'Πεταλουδών – Καμείρου – Ατταβύρου'};
  const gids={};
  for(const n of [1,2,3,4])gids[n]=await scalar(db,`insert into public.award_groups(configuration_id,group_no,name) values($1,$2,$3) returning id`,[configId,n,names[n]]);
  for(const r of rows)await db.query(`insert into public.award_group_memberships(configuration_id,award_group_id,municipal_unit_id) values($1,$2,$3)`,[configId,gids[Number(r.group_no)],Number(r.id)]);
  return {configId,unitId:Number(rows.find(r=>Number(r.group_no)===1).id)};
}

async function prepareStudy(db,{qty=10,price=5}={}){
  const {configId,unitId}=await activateGroups(db);
  const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
  const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
  const lock=await scalar(db,`select public.lock_study_atomic(null,$1,$2,2026,'Phase3',null,null,jsonb_build_array(jsonb_build_object('material_id',$3::text,'quantity',$4,'unit_price',$5,'comments',null)))`,[unitId,groupId,materialId,qty,price]);
  const supplierId=await scalar(db,`insert into public.mo_suppliers(name,created_by) values('Supplier',$1) returning id`,[ADMIN_ID]);
  const receiverId=await scalar(db,`insert into public.mo_receivers(name,created_by) values('Receiver',$1) returning id`,[ADMIN_ID]);
  return {configId,unitId,groupId,materialId,lock,supplierId,receiverId,studyNet:qty*price};
}

async function savePricingContract(db,x,{mode='study',discount=0,itemPrices=null,contractId=null}={}){
  return scalar(db,`select public.save_contract_pricing_atomic($1::text,$2::text,$3::text,'Contract',null,null,date '2026-08-01',date '2026-08-31',24,$4::text,$5::numeric,$6::jsonb)`,[
    contractId==null?null:String(contractId),x.lock.study_id,String(x.supplierId),mode,discount,itemPrices==null?null:JSON.stringify(itemPrices)
  ]);
}

async function contractItem(db,contractId){return (await db.query(`select * from public.mo_contract_items where contract_id=$1 order by id limit 1`,[contractId])).rows[0];}

function orderPayload(item,{qty=1,customPrice=null,mapQty=null}={}){
  if(customPrice!=null){
    return JSON.stringify([{contract_item_id:null,quantity:qty,unit_price:customPrice,description:'Εκτός τιμολογίου',unit:'τεμ.',mapping:[{contract_item_id:String(item.id),qty:mapQty??qty}]}]);
  }
  return JSON.stringify([{contract_item_id:String(item.id),quantity:qty,unit_price:Number(item.unit_price),description:item.description,unit:item.unit}]);
}

test('clean install φτάνει σε schema 36.6.5 και διαθέτει το νέο pricing RPC/guards',async()=>{
  const db=await install();
  try{
    assert.equal(await scalar(db,`select public.app_schema_version()`),'36.6.5');
    assert.equal(await scalar(db,`select to_regprocedure('public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)') is not null`),true);
    for(const [tableName,triggerName] of [
      ['mo_contracts','trg_mo_contracts_pricing_header_guard'],
      ['mo_contract_items','trg_mo_contract_items_pricing_guard'],
      ['mo_orders','trg_mo_orders_contract_financial_guard']
    ]) assert.equal(await scalar(db,`select exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname=$1 and t.tgname=$2 and not t.tgisinternal and t.tgenabled<>'D')`,[tableName,triggerName]),true);
  }finally{await db.close();}
});

test('ενιαία έκπτωση 10% αποθηκεύει πραγματικές συμβατικές τιμές και κρατά χωριστά την εκτιμώμενη αξία',async()=>{
  const db=await install();
  try{
    const x=await prepareStudy(db);
    const c=await savePricingContract(db,x,{mode:'discount',discount:10});
    const row=(await db.query(`select estimated_amount,total_amount,pricing_mode,discount_pct from public.mo_contracts where id=$1`,[c.contract_id])).rows[0];
    const item=await contractItem(db,c.contract_id);
    assert.equal(Number(row.estimated_amount),50);
    assert.equal(Number(row.total_amount),45);
    assert.equal(row.pricing_mode,'discount');
    assert.equal(Number(row.discount_pct),10);
    assert.equal(Number(item.estimated_unit_price),5);
    assert.equal(Number(item.unit_price),4.5);
  }finally{await db.close();}
});

test('πραγματική τιμή ανά είδος αποθηκεύεται και προσφορά πάνω από τη μελέτη απορρίπτεται',async()=>{
  const db=await install();
  try{
    const x=await prepareStudy(db);
    const c=await savePricingContract(db,x,{mode:'item_prices',itemPrices:[{material_id:String(x.materialId),unit_price:4.25}]});
    assert.equal(Number(await scalar(db,`select total_amount from public.mo_contracts where id=$1`,[c.contract_id])),42.5);
    assert.equal(Number((await contractItem(db,c.contract_id)).unit_price),4.25);
  }finally{await db.close();}

  const db2=await install();
  try{
    const x=await prepareStudy(db2);
    await assert.rejects(savePricingContract(db2,x,{mode:'item_prices',itemPrices:[{material_id:String(x.materialId),unit_price:6}]}),/υπερβαίνει την εκτιμώμενη αξία/i);
    assert.equal(Number(await scalar(db2,`select count(*) from public.mo_contracts where source_study_id=$1`,[x.lock.study_id])),0);
  }finally{await db2.close();}
});

test('εκδοθέν δελτίο δεν μπορεί να υπερβεί το πραγματικό συμβατικό ποσό',async()=>{
  const db=await install();
  try{
    const x=await prepareStudy(db);
    const c=await savePricingContract(db,x,{mode:'discount',discount:50});
    const contract=(await db.query(`select * from public.mo_contracts where id=$1`,[c.contract_id])).rows[0];
    const orderId=await scalar(db,`
      insert into public.mo_orders(order_date,supplier_id,contract_id,usage_location,vat_rate,subtotal,vat,total,status,municipal_unit_id,study_id,created_by)
      values(date '2026-08-15',$1,$2,'Test',24,26,6.24,32.24,'draft',$3,$4,$5) returning id`,[x.supplierId,c.contract_id,x.unitId,x.lock.study_id,ADMIN_ID]);
    assert.equal(Number(contract.total_amount),25);
    await assert.rejects(db.query(`update public.mo_orders set status='issued' where id=$1`,[orderId]),/υπερβαίνει το πραγματικό συμβατικό υπόλοιπο/i);
  }finally{await db.close();}
});

test('η «χρέωση ως» σε έκδοση απαιτεί ακριβή ίση αξία και όχι απλή υπερκάλυψη',async()=>{
  const db=await install();
  try{
    const x=await prepareStudy(db);
    const c=await savePricingContract(db,x,{mode:'study'});
    const item=await contractItem(db,c.contract_id);
    await assert.rejects(
      db.query(`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Test',null,24,$3::jsonb,true)`,[x.lock.study_id,String(x.receiverId),orderPayload(item,{customPrice:4,mapQty:1})]),
      /χρέωση ως.*ακριβώς ίση/i
    );
    const ok=await scalar(db,`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Test',null,24,$3::jsonb,true)`,[x.lock.study_id,String(x.receiverId),orderPayload(item,{customPrice:5,mapQty:1})]);
    assert.equal(ok.status,'issued');
  }finally{await db.close();}
});

test('μετά από εκδοθέν δελτίο δεν μεταβάλλεται η οικονομική τιμολόγηση της σύμβασης',async()=>{
  const db=await install();
  try{
    const x=await prepareStudy(db);
    const c=await savePricingContract(db,x,{mode:'study'});
    const item=await contractItem(db,c.contract_id);
    const issued=await scalar(db,`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Test',null,24,$3::jsonb,true)`,[x.lock.study_id,String(x.receiverId),orderPayload(item,{qty:1})]);
    assert.equal(issued.status,'issued');
    await assert.rejects(savePricingContract(db,x,{contractId:c.contract_id,mode:'discount',discount:10}),/δεν αλλάζει.*τιμ/i);
  }finally{await db.close();}
});

test('admin διορθώνει μόνο τα μεταδεδομένα απόφασης χωρίς να αλλάζουν οι τέσσερις ομάδες',async()=>{
  const db=await install();
  try{
    const {configId}=await activateGroups(db);
    const before=Number(await scalar(db,`select count(*) from public.award_group_memberships where configuration_id=$1`,[configId]));
    const result=await scalar(db,`select public.amend_award_group_decision_metadata(2026,'195/2026',date '2026-07-21','9ΑΒΓΩ1Ρ-123','Διόρθωση δοκιμαστικών μεταδεδομένων')`);
    const row=(await db.query(`select decision_number,decision_date::text,decision_ada,direct_award_cap from public.award_group_configurations where id=$1`,[configId])).rows[0];
    const after=Number(await scalar(db,`select count(*) from public.award_group_memberships where configuration_id=$1`,[configId]));
    assert.equal(result.groups_unchanged,true);
    assert.equal(row.decision_number,'195/2026');
    assert.equal(row.decision_date,'2026-07-21');
    assert.equal(row.decision_ada,'9ΑΒΓΩ1Ρ-123');
    assert.equal(Number(row.direct_award_cap),30000);
    assert.equal(after,before);
  }finally{await db.close();}
});
