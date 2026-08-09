import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql=fs.readFileSync(new URL('../supabase/108_VERIFY_V36_6_4.sql',import.meta.url),'utf8');

test('ο verifier v36.6.4 εντοπίζει τις RPC με to_regprocedure και όχι με ευάλωτη σύγκριση identity arguments',()=>{
  assert.match(sql,/to_regprocedure\('public\.import_catalog_request_atomic\(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb\)'\)/);
  assert.match(sql,/to_regprocedure\('public\.app_validate_request_lines\(bigint,jsonb\)'\)/);
  assert.match(sql,/pg_get_functiondef/);
  assert.match(sql,/m\.is_active is true/);
  assert.doesNotMatch(sql,/pg_get_function_identity_arguments\(p\.oid\)='text, bigint, bigint, integer, text, jsonb, jsonb, jsonb'/);
  assert.doesNotMatch(sql,/pg_get_function_identity_arguments\(p\.oid\)='bigint, jsonb'/);
});
