import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const source=fs.readFileSync(new URL('../index.html',import.meta.url),'utf8');
const html=source.replace(/<script\b[^>]*\bsrc=["'][^"']+["'][^>]*><\/script>/gi,'');

function query(data,error=null){
  const api={
    select(){return api;},eq(){return api;},limit(){return api;},order(){return api;},in(){return api;},
    single:async()=>({data,error}),maybeSingle:async()=>({data,error}),then(resolve){return Promise.resolve({data,error}).then(resolve);}
  };
  return api;
}

function runtime(){
  let rpcImpl=async()=>({data:null,error:null});
  const calls=[];
  let authListener=null;
  const dom=new JSDOM(html,{
    url:'https://test.local/',runScripts:'dangerously',pretendToBeVisual:true,
    beforeParse(window){
      Object.defineProperty(window.navigator,'onLine',{value:true,configurable:true});
      window.supabase={createClient:()=>({
        auth:{
          getSession:async()=>({data:{session:null},error:null}),
          signInWithPassword:async()=>({data:{session:{user:{id:'user-1'}}},error:null}),
          signOut:async()=>({error:null}),
          onAuthStateChange(cb){authListener=cb;return {data:{subscription:{unsubscribe(){}}}};}
        },
        from(){return query([]);},
        async rpc(name,args){calls.push({name,args});return rpcImpl(name,args);}
      })};
      window.ExcelJS={};
      window.ResizeObserver=class{observe(){} disconnect(){}};
      window.confirm=()=>true;window.prompt=()=>null;window.open=()=>null;
    }
  });
  return {dom,calls,setRpc(fn){rpcImpl=fn;},authEvent(event,session=null){authListener?.(event,session);}};
}

const sleep=ms=>new Promise(r=>setTimeout(r,ms));

test('frontend v36.6.6 χρησιμοποιεί μόνο resilient critical write entry points',()=>{
  assert.match(source,/APP_VERSION='v36\.6\.6-production-resilience'/);
  assert.match(source,/REQUIRED_SCHEMA_VERSION='36\.6\.6'/);
  for(const name of [
    'save_unit_request_resilient_atomic','lock_study_resilient_atomic',
    'secure_import_catalog_request_resilient_atomic','copy_unit_request_resilient_atomic',
    'load_study_template_resilient_atomic','save_contract_pricing_resilient_atomic','save_order_resilient_atomic'
  ]) assert.match(source,new RegExp(name));
  for(const old of [
    "sb.rpc('save_unit_request_atomic'","sb.rpc('lock_study_atomic'",
    "sb.rpc('secure_import_catalog_request_atomic'","sb.rpc('copy_unit_request_atomic'",
    "sb.rpc('load_study_template_atomic'","sb.rpc('save_contract_pricing_atomic'",
    "sb.rpc('save_contract_atomic'","sb.rpc('save_order_atomic'"
  ]) assert.equal(source.includes(old),false,old);
  assert.match(source,/let reqId=null, reqRevision=0/);
  assert.match(source,/onAuthStateChange/);
  assert.match(source,/SESSION_RECOVERY/);
});

test('network failure επαναλαμβάνεται μία φορά με ακριβώς το ίδιο operation_id',async()=>{
  const r=runtime();
  try{
    let n=0;
    r.setRpc(async()=>++n===1?{data:null,error:{message:'Failed to fetch'}}:{data:{ok:true},error:null});
    const result=await r.dom.window.resilientRpc('demo',{p_value:1},'demo-key');
    assert.equal(result.error,null);
    assert.equal(r.calls.length,2);
    assert.equal(r.calls[0].args.p_operation_id,r.calls[1].args.p_operation_id);
    assert.equal(r.calls[0].args.p_value,1);
  }finally{r.dom.window.close();}
});

test('αβέβαιο network failure κρατά operation_id για μεταγενέστερο χειροκίνητο retry',async()=>{
  const r=runtime();
  try{
    r.setRpc(async()=>({data:null,error:{message:'NetworkError: connection lost'}}));
    const first=await r.dom.window.resilientRpc('demo',{p_value:2},'uncertain-key');
    assert.ok(first.error);
    assert.equal(r.calls.length,2);
    const firstId=r.calls[0].args.p_operation_id;
    assert.equal(firstId,r.calls[1].args.p_operation_id);

    r.setRpc(async()=>({data:{ok:true},error:null}));
    const second=await r.dom.window.resilientRpc('demo',{p_value:2},'uncertain-key');
    assert.equal(second.error,null);
    assert.equal(r.calls.length,3);
    assert.equal(r.calls[2].args.p_operation_id,firstId);
  }finally{r.dom.window.close();}
});

test('validation/concurrency error δεν κάνει automatic retry και καθαρίζει την παλιά operation',async()=>{
  const r=runtime();
  try{
    r.setRpc(async()=>({data:null,error:{code:'40001',message:'Το πρόχειρο άλλαξε από άλλο χρήστη.'}}));
    const first=await r.dom.window.resilientRpc('demo',{p_value:3},'validation-key');
    assert.ok(first.error);
    assert.equal(r.calls.length,1);
    const firstId=r.calls[0].args.p_operation_id;

    r.setRpc(async()=>({data:{ok:true},error:null}));
    await r.dom.window.resilientRpc('demo',{p_value:3},'validation-key');
    assert.equal(r.calls.length,2);
    assert.notEqual(r.calls[1].args.p_operation_id,firstId);
  }finally{r.dom.window.close();}
});

test('session-expired error δεν κάνει τυφλό retry και κρατά pending operation για επανασύνδεση',async()=>{
  const r=runtime();
  try{
    r.dom.window.eval("ME={id:'user-1',role:'admin',unitId:null,name:'Test',email:'x',canSupervise:true}");
    r.setRpc(async()=>({data:null,error:{status:401,message:'JWT expired'}}));
    const first=await r.dom.window.resilientRpc('demo',{p_value:4},'session-key');
    assert.ok(first.error);
    assert.equal(r.calls.length,1);
    const id=r.calls[0].args.p_operation_id;
    assert.equal(r.dom.window.document.querySelector('#login').classList.contains('hidden'),false);
    assert.equal(r.dom.window.document.querySelector('#app').classList.contains('hidden'),true);

    r.setRpc(async()=>({data:{ok:true},error:null}));
    await r.dom.window.resilientRpc('demo',{p_value:4},'session-key');
    assert.equal(r.calls[1].args.p_operation_id,id);
  }finally{r.dom.window.close();}
});
