import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT=fileURLToPath(new URL('../',import.meta.url));
const read=p=>fs.readFileSync(path.join(ROOT,p),'utf8');

function walk(dir,acc=[]){
  for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
    if(['.git','node_modules'].includes(entry.name))continue;
    const full=path.join(dir,entry.name);
    if(entry.isDirectory())walk(full,acc);
    else acc.push(full);
  }
  return acc;
}

test('production frontend stays within static delivery budget',()=>{
  const htmlPath=path.join(ROOT,'index.html');
  const size=fs.statSync(htmlPath).size;
  assert.ok(size<=700_000,`index.html exceeds 700 KB budget: ${size} bytes`);
  const html=read('index.html');
  assert.match(html,/const SUPABASE_KEY='sb_publishable_[^']+'/);
  assert.doesNotMatch(html,/sb_secret_/i);
  assert.doesNotMatch(html,/service_role[^\n]{0,80}(?:key|secret|token)/i);
  assert.match(html,/script-src-attr 'none'/);
  assert.match(html,/object-src 'none'/);
  assert.match(html,/base-uri 'none'/);
  assert.match(html,/form-action 'none'/);
  assert.match(html,/frame-src 'none'/);
  assert.match(html,/connect-src https:\/\/omncqldgtkdcjpqfwwlr\.supabase\.co wss:\/\/omncqldgtkdcjpqfwwlr\.supabase\.co/);
});

test('repository contains no obvious committed secrets',()=>{
  const candidates=walk(ROOT).filter(file=>{
    const rel=path.relative(ROOT,file).replaceAll('\\','/');
    if(rel==='package-lock.json')return false;
    return /\.(?:html|mjs|js|json|ya?ml|sql|md|ps1|bat)$/i.test(rel);
  });
  const checks=[
    [/sb_secret_[A-Za-z0-9._-]+/i,'Supabase secret key'],
    [/SUPABASE_SERVICE_ROLE_KEY\s*[:=]\s*['\"][^'\"]+/i,'Supabase service-role key assignment'],
    [/postgres(?:ql)?:\/\/[^\s:'\"]+:[^\s@'\"]+@/i,'database URI with embedded password'],
    [/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,'private key'],
    [/\bghp_[A-Za-z0-9]{30,}\b/,'GitHub classic token'],
    [/\bgithub_pat_[A-Za-z0-9_]{20,}\b/,'GitHub fine-grained token'],
    [/\bAKIA[0-9A-Z]{16}\b/,'AWS access key']
  ];
  const findings=[];
  for(const file of candidates){
    const text=fs.readFileSync(file,'utf8');
    for(const [re,label] of checks){
      if(re.test(text))findings.push(`${path.relative(ROOT,file)}: ${label}`);
    }
  }
  assert.deepEqual(findings,[]);
});

test('GitHub Actions surface is minimal and immutable',()=>{
  const workflowDir=path.join(ROOT,'.github','workflows');
  const files=fs.readdirSync(workflowDir).filter(x=>/\.ya?ml$/i.test(x)).sort();
  assert.deepEqual(files,['test.yml']);
  const yml=read('.github/workflows/test.yml');
  assert.match(yml,/permissions:\s*\n\s*contents: read/);
  assert.doesNotMatch(yml,/pull_request_target:/);
  assert.doesNotMatch(yml,/permissions:[\s\S]{0,160}\bwrite\b/i);
  assert.match(yml,/npm ci --ignore-scripts --no-audit --no-fund/);
  const uses=[...yml.matchAll(/^\s*uses:\s*([^\s#]+)/gm)].map(m=>m[1]);
  assert.ok(uses.length>=3,'expected pinned GitHub actions');
  for(const ref of uses){
    assert.match(ref,/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+@[0-9a-f]{40}$/i,`action is not pinned to full SHA: ${ref}`);
  }
});

test('local servers bind only to loopback',()=>{
  const node=read('local-server.mjs');
  const ps=read('local-server.ps1');
  const bat=read('start-local.bat');
  assert.match(node,/const HOST = '127\.0\.0\.1'/);
  assert.match(ps,/127\.0\.0\.1/);
  assert.match(bat,/--bind 127\.0\.0\.1/);
});
