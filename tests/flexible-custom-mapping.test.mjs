/*
 * Αντιστοίχιση («χρέωση ως») γραμμών εκτός τιμολογίου χωρίς απαίτηση ίσου ποσού.
 *
 * Ο κανόνας που ελέγχεται: η αντιστοίχιση δηλώνει ΠΟΥ χρεώνεται μια ελεύθερη
 * γραμμή και αναλώνει συμβατικές ΠΟΣΟΤΗΤΕΣ. Το ΧΡΗΜΑ αφαιρείται από τη σύμβαση
 * με την πραγματική αξία της γραμμής. Άρα η διαφορά αξίας είναι επιτρεπτή, ενώ
 * τα δύο πλαφόν (χρήμα σύμβασης, ποσότητα ανά είδος) παραμένουν απαράβατα.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const ADMIN_ID='11111111-1111-1111-1111-111111111111';
const migrationsDir=fileURLToPath(new URL('../supabase/migrations/',import.meta.url));
const source=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');

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
    insert into auth.users(id,email) values ('${ADMIN_ID}','admin@rhodes.gr');
    insert into public.profiles(id,role,municipal_unit_id,full_name,email,is_active)
    values ('${ADMIN_ID}','admin',null,'Admin','admin@rhodes.gr',true) on conflict(id) do nothing;
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

async function contractedStudy(db,{qty=10,price=5}={}){
  const rows=(await db.query(`select id::bigint id,public.app_rhodes_award_group_no(id::bigint)::int group_no from public.municipal_units where id<>11 order by id`)).rows;
  const configId=await scalar(db,`
    insert into public.award_group_configurations(budget_year,decision_number,decision_date,decision_ada,direct_award_cap,is_active,created_by,updated_by)
    values(2026,'TEST/2026',date '2026-08-01','TEST',30000,true,$1,$1) returning id`,[ADMIN_ID]);
  const names={1:'Ρόδου',2:'Ιαλυσού – Καλλιθέας – Αφάντου',3:'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου',4:'Πεταλουδών – Καμείρου – Ατταβύρου'};
  const gids={};
  for(const n of [1,2,3,4])gids[n]=await scalar(db,`insert into public.award_groups(configuration_id,group_no,name) values($1,$2,$3) returning id`,[configId,n,names[n]]);
  for(const r of rows)await db.query(`insert into public.award_group_memberships(configuration_id,award_group_id,municipal_unit_id) values($1,$2,$3)`,[configId,gids[Number(r.group_no)],Number(r.id)]);
  const unitId=Number(rows.find(r=>Number(r.group_no)===1).id);
  const groupId=await scalar(db,`select id from public.procurement_groups where domain='procurement' order by id limit 1`);
  const materialId=await scalar(db,`select id from public.materials where group_id=$1 and is_active order by id limit 1`,[groupId]);
  const lock=await scalar(db,`select public.lock_study_atomic(null,$1,$2,2026,'Ευέλικτη αντιστοίχιση',null,null,jsonb_build_array(jsonb_build_object('material_id',$3::text,'quantity',$4::numeric,'unit_price',$5::numeric,'comments',null)))`,[unitId,groupId,materialId,qty,price]);
  const supplierId=await scalar(db,`insert into public.mo_suppliers(name,created_by) values('Ανάδοχος',$1) returning id`,[ADMIN_ID]);
  const receiverId=await scalar(db,`insert into public.mo_receivers(name,created_by) values('Παραλαμβάνων',$1) returning id`,[ADMIN_ID]);
  const c=await scalar(db,`select public.save_contract_pricing_atomic(null,$1::text,$2::text,'Σύμβαση',null,null,date '2026-08-01',date '2026-08-31',24,'study',0,null)`,[lock.study_id,String(supplierId)]);
  const item=(await db.query(`select * from public.mo_contract_items where contract_id=$1 order by id limit 1`,[c.contract_id])).rows[0];
  return {lock,receiverId,contractId:c.contract_id,item};
}

function custom(item,{qty=1,price=1,mapQty=null,mapping=undefined}={}){
  const map=mapping!==undefined?mapping:[{contract_item_id:String(item.id),qty:mapQty}];
  return JSON.stringify([{contract_item_id:null,quantity:qty,unit_price:price,description:'Εργασία εκτός τιμολογίου',unit:'τεμ.',mapping:map}]);
}
function saveOrder(db,x,items,issue){
  return scalar(db,`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Αποθήκη',null,24,$3::jsonb,$4)`,
    [x.lock.study_id,String(x.receiverId),items,issue]);
}

test('άνιση αντιστοίχιση εκδίδεται· από τη σύμβαση φεύγει η πραγματική αξία της γραμμής',async()=>{
  const db=await install();
  try{
    const x=await contractedStudy(db);            // 10 τεμ. × 5 € = 50 €
    // 47,30 € χρεωμένα ως 9 τεμ. × 5 € = 45 € — διαφορά −2,30 €, καμία ταύτιση.
    const o=await saveOrder(db,x,custom(x.item,{qty:1,price:47.30,mapQty:9}),true);
    assert.equal(o.status,'issued');
    const bal=await scalar(db,`select public.get_contract_balance_atomic($1)`,[x.contractId]);
    assert.equal(Number(bal.contract_total),50);
    assert.equal(Number(bal.committed_net),47.30,'το χρήμα δεσμεύεται από την αξία της γραμμής, όχι της αντιστοίχισης');
    assert.equal(Number(bal.items[0].committed_qty),9,'η αντιστοίχιση αναλώνει συμβατικές ποσότητες');
    assert.equal(Number(bal.items[0].remaining_qty),1);
  }finally{await db.close();}
});

test('υπερκάλυψη από στρογγυλοποίηση ποσότητας επιτρέπεται',async()=>{
  const db=await install();
  try{
    const x=await contractedStudy(db);
    // 12,40 € που καμία ακέραια ποσότητα των 5 € δεν δίνει ακριβώς: 3 τεμ. = 15 €.
    const o=await saveOrder(db,x,custom(x.item,{qty:1,price:12.40,mapQty:3}),true);
    assert.equal(o.status,'issued');
    const bal=await scalar(db,`select public.get_contract_balance_atomic($1)`,[x.contractId]);
    assert.equal(Number(bal.committed_net),12.40);
    assert.equal(Number(bal.items[0].committed_qty),3);
  }finally{await db.close();}
});

test('το πλαφόν συμβατικής ΠΟΣΟΤΗΤΑΣ παραμένει απαράβατο για την αντιστοίχιση',async()=>{
  const db=await install();
  try{
    const x=await contractedStudy(db);            // contract_qty = 10
    await assert.rejects(
      db.query(`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Αποθήκη',null,24,$3::jsonb,true)`,
        [x.lock.study_id,String(x.receiverId),custom(x.item,{qty:1,price:1,mapQty:11})]),
      /Υπέρβαση συμβατικής ποσότητας/i);
  }finally{await db.close();}
});

test('το πλαφόν ΧΡΗΜΑΤΟΣ της σύμβασης παραμένει απαράβατο',async()=>{
  const db=await install();
  try{
    const x=await contractedStudy(db);            // σύμβαση 50 €
    await assert.rejects(
      db.query(`select public.save_order_atomic(null,$1,date '2026-08-15',$2,'Αποθήκη',null,24,$3::jsonb,true)`,
        [x.lock.study_id,String(x.receiverId),custom(x.item,{qty:1,price:60,mapQty:1})]),
      /υπερβ/i);
  }finally{await db.close();}
});

test('ο trigger κόβει την έκδοση δελτίου με ελεύθερη γραμμή χωρίς αντιστοίχιση',async()=>{
  const db=await install();
  try{
    const x=await contractedStudy(db);
    const draft=await saveOrder(db,x,custom(x.item,{qty:1,price:9,mapping:[]}),false);
    assert.equal(draft.status,'draft');
    assert.equal(await scalar(db,`select mapping is null from public.mo_order_items where order_id=$1`,[draft.order_id]),true);
    await assert.rejects(
      db.query(`update public.mo_orders set status='issued' where id=$1`,[draft.order_id]),
      /τουλάχιστον μία αντιστοίχιση/i,
      'χωρίς τον έλεγχο, μια χρέωση θα έμενε χωρίς συμβατικό έρεισμα');
  }finally{await db.close();}
});

/* ---------------------------------------------------------------- client ---- */

const sandbox=vm.createContext({});
for(const pattern of [
  /function parseMapping\(it\)\{[\s\S]*?\n\}/,
  /function mappingCovered\(line\)\{[\s\S]*?\n\}/
]){
  const code=source.match(pattern)?.[0];
  assert.ok(code,'δεν βρέθηκε ο κανόνας αντιστοίχισης στο index.html');
  vm.runInContext(code,sandbox);
}
vm.runInContext(`
  var st={citems:[{id:'a',unit_price:5,unit:'τεμ.',description:'Είδος Α'},{id:'b',unit_price:12.5,unit:'τεμ.',description:'Είδος Β'}]};
  function byId(arr,id){return (arr||[]).find(x=>String(x.id)===String(id))||null;}
  function num(v){const n=Number(String(v==null?'':v).replace(',','.'));return isFinite(n)?n:0;}
`,sandbox);
const mappingCovered=vm.runInContext('mappingCovered',sandbox);

test('η κάλυψη υπολογίζεται από τις συμβατικές τιμές, σε όποια απόσταση κι αν είναι',()=>{
  assert.equal(mappingCovered({mapping:[{contract_item_id:'a',qty:9}]}),45);
  assert.equal(mappingCovered({mapping:'[{"contract_item_id":"b","qty":2}]'}),25);
  assert.equal(mappingCovered({mapping:[{contract_item_id:'a',qty:1},{contract_item_id:'b',qty:1}]}),17.5);
  assert.equal(mappingCovered({mapping:[]}),0);
  assert.equal(mappingCovered({}),0);
});

test('η έκδοση μπλοκάρει μόνο για ελεύθερη γραμμή χωρίς αντιστοίχιση',()=>{
  const fn=source.slice(source.indexOf('function validate(o,forIssue)'),
                        source.indexOf('async function persistOrder'));
  assert.match(fn,/it\.is_custom&&it\.quantity\*it\.unit_price>0\.005&&!parseMapping\(it\)\.length/,
    'ο μόνος αποκλεισμός πρέπει να είναι η απουσία αντιστοίχισης σε γραμμή με αξία');
  assert.ok(!/Math\.abs\(cov-c\)/.test(fn),
    'δεν επιτρέπεται να έχει μείνει απαίτηση ίσου ποσού στην έκδοση');
  assert.match(fn,/Δεν χρειάζεται ίσο ποσό/,'το μήνυμα πρέπει να λέει τι ΔΕΝ απαιτείται');
});

test('η διαφορά αξίας εμφανίζεται ως πληροφορία, όχι ως σφάλμα',()=>{
  const fn=source.slice(source.indexOf('function renderBalance()'),
                        source.indexOf('renderBalance();\n  const cNotes'));
  assert.match(fn,/mappingMissing\+\+/);
  assert.match(fn,/if\(mappingMissing\)balHost\.append\(el\("div",\{class:"mo-callout mo-cerr"\}/,
    'μόνο η απουσία αντιστοίχισης είναι σφάλμα');
  assert.match(fn,/else if\(Math\.abs\(mappingDiff\)>0\.005\)balHost\.append\(el\("div",\{class:"mo-callout"\}/,
    'η διαφορά αξίας είναι απλή ενημέρωση');
  assert.match(fn,/Δεν εμποδίζει την έκδοση/);
});

test('το modal αντιστοίχισης δεν ζητά πια ισόποση κάλυψη',()=>{
  const fn=source.slice(source.indexOf('function openMappingModal(line)'),
                        source.indexOf('renderItemsTable();\n  /* δεξιά στήλη */'));
  assert.match(fn,/totEl\.style\.color=c<=0\?"var\(--mo-err\)":"var\(--mo-ok\)"/,
    'κόκκινο μόνο όταν δεν έχει επιλεγεί τίποτα');
  assert.match(fn,/Δεν χρειάζεται να βγει ακριβώς το ίδιο ποσό/);
  assert.ok(!/ισόποσα/.test(fn),'η παλιά οδηγία «ισόποσα» πρέπει να έχει φύγει');
});
