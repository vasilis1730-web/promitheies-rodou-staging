from pathlib import Path
import json,re,hashlib,base64

p=Path('index.html')
s=p.read_text(encoding='utf-8')

def once(old,new,label):
    global s
    n=s.count(old)
    if n!=1: raise SystemExit(f'{label}: expected 1 occurrence, found {n}')
    s=s.replace(old,new,1)

once('<title>Δήμος Ρόδου · Προμήθειες &amp; Υπηρεσίες v36.6.5 CONTRACT PRICING</title>',
     '<title>Δήμος Ρόδου · Προμήθειες &amp; Υπηρεσίες v36.6.6 PRODUCTION RESILIENCE</title>','title')
once("const APP_VERSION='v36.6.5-contract-pricing', REQUIRED_SCHEMA_VERSION='36.6.5';",
     "const APP_VERSION='v36.6.6-production-resilience', REQUIRED_SCHEMA_VERSION='36.6.6';",'version')
once("'v36.6.3-production-readiness','v36.6.5-contract-pricing']);",
     "'v36.6.3-production-readiness','v36.6.5-contract-pricing','v36.6.6-production-resilience']);",'excel versions')

client_anchor="""const sb=(window.supabase&&typeof window.supabase.createClient==='function')
  ? window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY)
  : null;

const $=s=>document.querySelector(s);"""
client_new="""const sb=(window.supabase&&typeof window.supabase.createClient==='function')
  ? window.supabase.createClient(SUPABASE_URL,SUPABASE_KEY)
  : null;

let MANUAL_LOGOUT=false, SESSION_RECOVERY=false;
const PENDING_OPERATIONS=new Map();
function newOperationId(){
  if(window.crypto&&typeof window.crypto.randomUUID==='function')return window.crypto.randomUUID();
  const b=new Uint8Array(16);window.crypto.getRandomValues(b);b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;
  const h=[...b].map(x=>x.toString(16).padStart(2,'0')).join('');
  return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);
}
function rpcSignature(args){try{return JSON.stringify(args||{});}catch{return String(Date.now());}}
function isTransportFailure(error){
  const msg=String(error&&error.message||error||'');
  return navigator.onLine===false||/failed to fetch|network(?:error)?|load failed|fetch failed|timeout|timed out|connection.*(?:closed|reset|lost)|socket/i.test(msg);
}
function isSessionExpiredError(error){
  const status=Number(error&&error.status)||0,code=String(error&&error.code||'');
  const msg=String(error&&error.message||error||'');
  return status===401||code==='PGRST301'||/jwt.*(?:expired|invalid)|token.*expired|session.*expired|refresh token/i.test(msg);
}
function enterSessionRecovery(message){
  if(!ME||!ME.id)return;
  SESSION_RECOVERY=true;
  $('#login').classList.remove('hidden');
  $('#app').classList.add('hidden');
  showLoginError(message||'Η συνεδρία έληξε. Συνδεθείτε ξανά. Οι μη αποθηκευμένες αλλαγές παραμένουν σε αυτή την καρτέλα και δεν θα αντικατασταθούν κατά την επανασύνδεση.');
}
async function resumeSessionAfterLogin(session){
  if(!session||!session.user)throw new Error('Η επανασύνδεση δεν δημιούργησε ενεργή συνεδρία.');
  const results=await Promise.all([
    sb.from('profiles').select('role,municipal_unit_id,full_name,email').eq('id',session.user.id).single(),
    sb.from('user_app_permissions').select('can_supervise').eq('user_id',session.user.id).maybeSingle(),
    sb.rpc('app_schema_version')
  ]);
  const prof=results[0].data,profileError=results[0].error,perm=results[1].data,permError=results[1].error;
  const schemaVersion=results[2].data,schemaError=results[2].error;
  if(profileError||!prof)throw new Error('Δεν βρέθηκε ενεργό προφίλ εφαρμογής μετά την επανασύνδεση.');
  if(permError||schemaError)throw new Error('Δεν ολοκληρώθηκε ο έλεγχος δικαιωμάτων μετά την επανασύνδεση.');
  if(String(schemaVersion)!==REQUIRED_SCHEMA_VERSION)throw new Error('Η βάση δεν βρίσκεται στην απαιτούμενη έκδοση '+REQUIRED_SCHEMA_VERSION+'.');
  ME={id:session.user.id,role:prof.role,unitId:prof.municipal_unit_id,email:prof.email,name:prof.full_name||prof.email||'Χρήστης',canSupervise:!!(perm&&perm.can_supervise)};
  SESSION_RECOVERY=false;
  clearLoginError();$('#login').classList.add('hidden');$('#app').classList.remove('hidden');
  $('#whoName').textContent=ME.name;$('#whoRole').textContent=ROLE_LABEL[ME.role]||ME.role;
  updateAdminControls();if(typeof render==='function')render();
  toast('Η συνεδρία αποκαταστάθηκε. Οι μη αποθηκευμένες αλλαγές διατηρήθηκαν. Μπορείτε να επαναλάβετε την ενέργεια.','accent');
}
async function resilientRpc(name,args,operationKey){
  if(!sb)return {data:null,error:new Error('Δεν υπάρχει σύνδεση με τη βάση.')};
  const key=String(operationKey||name),signature=rpcSignature(args);
  let pending=PENDING_OPERATIONS.get(key);
  if(!pending||pending.signature!==signature){pending={id:newOperationId(),signature};PENDING_OPERATIONS.set(key,pending);}
  const callArgs={p_operation_id:pending.id,...args};
  for(let attempt=0;attempt<2;attempt++){
    let result;
    try{result=await sb.rpc(name,callArgs);}catch(error){result={data:null,error};}
    if(!result||!result.error){PENDING_OPERATIONS.delete(key);return result||{data:null,error:null};}
    if(isSessionExpiredError(result.error)){enterSessionRecovery();return result;}
    if(!isTransportFailure(result.error)){PENDING_OPERATIONS.delete(key);return result;}
    if(attempt===0&&navigator.onLine!==false){await new Promise(resolve=>setTimeout(resolve,300));continue;}
    return result;
  }
}

const $=s=>document.querySelector(s);"""
once(client_anchor,client_new,'resilience helpers')

once("let reqId=null, lines={}, baseline={}, dirty=false, prefillHint=false, cleanView=false;",
     "let reqId=null, reqRevision=0, lines={}, baseline={}, dirty=false, prefillHint=false, cleanView=false;",'revision global')
s=s.replace('reqId=null; lines={};','reqId=null; reqRevision=0; lines={};')
s=s.replace('reqId=null;lines={};','reqId=null;reqRevision=0;lines={};')

once("""async function loadUnitRequest(){
  if(cur.unitId==null||cur.groupId==null)return;
  const {data:reqs,error}=await sb.from('unit_requests').select('id,status')""",
     """async function loadUnitRequest(){
  if(cur.unitId==null||cur.groupId==null)return;
  reqRevision=0;
  const {data:reqs,error}=await sb.from('unit_requests').select('id,status,revision')""",'load request select')
once("if(reqs&&reqs.length){ reqId=reqs[0].id; cleanView=(reqs[0].status==='cleaned');",
     "if(reqs&&reqs.length){ reqId=reqs[0].id; reqRevision=Number(reqs[0].revision)||0; cleanView=(reqs[0].status==='cleaned');",'load revision')

once("const {error}=await sb.auth.signInWithPassword({email,password});\n    if(error){showLoginError(authErrorMessage(error));return;}\n    const result=await boot();",
     "const {data,error}=await sb.auth.signInWithPassword({email,password});\n    if(error){showLoginError(authErrorMessage(error));return;}\n    if(SESSION_RECOVERY&&ME.id){await resumeSessionAfterLogin(data&&data.session);return;}\n    const result=await boot();",'login resume')
once("$('#logoutBtn').onclick=async()=>{if(sb)await sb.auth.signOut();location.reload();};",
     "$('#logoutBtn').onclick=async()=>{MANUAL_LOGOUT=true;if(sb)await sb.auth.signOut();location.reload();};\nif(sb&&sb.auth&&typeof sb.auth.onAuthStateChange==='function'){\n  sb.auth.onAuthStateChange((event)=>{if(event==='SIGNED_OUT'&&!MANUAL_LOGOUT&&ME.id)enterSessionRecovery();});\n}",'auth state listener')

pat=re.compile(r"const \{data,error\}=await sb\.rpc\('save_unit_request_atomic',\{(.*?)\n    \}\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('save request RPC not found')
body=m.group(1)
s=pat.sub(lambda _:"const {data,error}=await resilientRpc('save_unit_request_resilient_atomic',{\n      p_expected_revision:reqRevision,"+body+"\n    },'request:'+cur.unitId+':'+cur.groupId+':'+YEAR+':'+(clean?'clean':'save'));",s,count=1)

pat=re.compile(r"const \{data,error\}=await sb\.rpc\('lock_study_atomic',\{(.*?)\n    \}\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('lock RPC not found')
body=m.group(1)
s=pat.sub(lambda _:"const {data,error}=await resilientRpc('lock_study_resilient_atomic',{\n      p_expected_revision:reqRevision,"+body+"\n    },'lock:'+cur.unitId+':'+cur.groupId+':'+YEAR);",s,count=1)

marker="if(data&&data.request_id!=null)reqId=data.request_id;"
count=s.count(marker)
if count<4: raise SystemExit(f'expected >=4 request_id response markers, found {count}')
s=s.replace(marker,marker+"\n    if(data&&data.revision!=null)reqRevision=Number(data.revision)||0;")

pat=re.compile(r"const \{data,error\}=await sb\.rpc\('secure_import_catalog_request_atomic',\{(.*?)\n    \}\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('Excel import RPC not found')
body=m.group(1)
s=pat.sub(lambda _:"const {data,error}=await resilientRpc('secure_import_catalog_request_resilient_atomic',{\n      p_expected_revision:reqRevision,"+body+"\n    },'excel:'+String(importContext.exportToken));",s,count=1)

pat=re.compile(r"const \{error\}=await sb\.rpc\('copy_unit_request_atomic',\{(.*?)\n    \}\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('copy RPC not found')
body=m.group(1)
copy_repl="""const {data:destReqs,error:destReqError}=await sb.from('unit_requests').select('id,revision')
      .eq('municipal_unit_id',destId).eq('group_id',cur.groupId).eq('request_year',YEAR).limit(1);
    if(destReqError)throw destReqError;
    const destRevision=(destReqs&&destReqs.length)?(Number(destReqs[0].revision)||0):0;
    const {error}=await resilientRpc('copy_unit_request_resilient_atomic',{
      p_expected_destination_revision:destRevision,"""+body+"\n    },'copy:'+destId+':'+cur.groupId+':'+YEAR);"
s=pat.sub(lambda _:copy_repl,s,count=1)

pat=re.compile(r"const \{data,error\}=await sb\.rpc\('load_study_template_atomic',\{(.*?)\n    \}\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('template load RPC not found')
body=m.group(1)
s=pat.sub(lambda _:"const {data,error}=await resilientRpc('load_study_template_resilient_atomic',{\n      p_expected_revision:reqRevision,"+body+"\n    },'template-load:'+cur.unitId+':'+cur.groupId+':'+YEAR);",s,count=1)

pat=re.compile(r"\(\{error\}=await sb\.rpc\('save_contract_pricing_atomic',\{(.*?)\n          \}\)\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('new contract RPC not found')
body=m.group(1)
s=pat.sub(lambda _:"({error}=await resilientRpc('save_contract_pricing_resilient_atomic',{"+body+"\n          },'contract:'+String(stdy.id)));",s,count=1)

old="""({error}=await sb.rpc('save_contract_atomic',{
            p_contract_id:String(existing.id),p_study_id:String(stdy.id),p_supplier_id:String(supplier_id),p_title:autoTitle,
            p_adam:data.adam,p_protocol_no:data.protocol_no,p_start_date:data.start_date,p_end_date:data.end_date,p_vat_rate:num(existing.vat_rate)
          }));"""
new="""({error}=await resilientRpc('save_contract_pricing_resilient_atomic',{
            p_contract_id:String(existing.id),p_study_id:String(stdy.id),p_supplier_id:String(supplier_id),p_title:autoTitle,
            p_adam:data.adam,p_protocol_no:data.protocol_no,p_start_date:data.start_date,p_end_date:data.end_date,p_vat_rate:num(existing.vat_rate),
            p_pricing_mode:existing.pricing_mode||'study',p_discount_pct:num(existing.discount_pct),p_item_prices:null
          },'contract:'+String(stdy.id)));"""
once(old,new,'existing contract resilient RPC')

pat=re.compile(r"const \{data,error\}=await sb\.rpc\('save_order_atomic',\{(.*?)\n  \}\);",re.S)
m=pat.search(s)
if not m: raise SystemExit('order RPC not found')
body=m.group(1)
s=pat.sub(lambda _:"const {data,error}=await resilientRpc('save_order_resilient_atomic',{\n    "+body+"\n  },'order:'+String(o.id||st.study.id)+':'+(forIssue?'issue':'save'));",s,count=1)

forbidden=["sb.rpc('save_unit_request_atomic'","sb.rpc('lock_study_atomic'","sb.rpc('secure_import_catalog_request_atomic'","sb.rpc('copy_unit_request_atomic'","sb.rpc('load_study_template_atomic'","sb.rpc('save_contract_pricing_atomic'","sb.rpc('save_contract_atomic'","sb.rpc('save_order_atomic'"]
bad=[x for x in forbidden if x in s]
if bad: raise SystemExit('legacy browser RPC calls remain: '+', '.join(bad))

scripts=re.findall(r'<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>',s,flags=re.I|re.S)
if len(scripts)!=2: raise SystemExit(f'expected 2 inline scripts, found {len(scripts)}')
hashes=["'sha256-"+base64.b64encode(hashlib.sha256(x.encode('utf-8')).digest()).decode()+"'" for x in scripts]
meta=re.search(r'<meta http-equiv="Content-Security-Policy" content="([^"]+)">',s)
if not meta: raise SystemExit('CSP meta not found')
directives=meta.group(1).split(';')
for i,d in enumerate(directives):
    if d.strip().startswith('script-src '):
        tokens=[t for t in d.strip().split() if not t.startswith("'sha256-")]
        directives[i]=' '.join(tokens+hashes)
        break
else: raise SystemExit('script-src CSP directive missing')
new_csp=';'.join(directives)
s=s[:meta.start(1)]+new_csp+s[meta.end(1):]
p.write_text(s,encoding='utf-8')

for fn in ['package.json','package-lock.json']:
    pp=Path(fn);obj=json.loads(pp.read_text(encoding='utf-8'));obj['version']='36.6.6'
    if fn=='package-lock.json' and '' in obj.get('packages',{}):obj['packages']['']['version']='36.6.6'
    pp.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

pp=Path('tests/login-bootstrap.test.mjs');t=pp.read_text(encoding='utf-8')
if "REQUIRED_SCHEMA_VERSION='36\\.6\\.5'" not in t: raise SystemExit('login version expectation anchor missing')
t=t.replace("REQUIRED_SCHEMA_VERSION='36\\.6\\.5'","REQUIRED_SCHEMA_VERSION='36\\.6\\.6'",1)
pp.write_text(t,encoding='utf-8')
