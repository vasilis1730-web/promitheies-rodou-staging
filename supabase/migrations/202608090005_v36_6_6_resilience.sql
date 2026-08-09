-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — v36.6.6 PRODUCTION RESILIENCE
--
-- Στόχοι:
-- 1. Idempotency για κρίσιμες write RPCs ώστε network retry / double click
--    να μην δημιουργεί δεύτερη μελέτη, σύμβαση, δελτίο ή Excel import.
-- 2. Optimistic concurrency στα unit_requests μέσω revision.
-- 3. Ασφαλές retry μετά από αβέβαιη δικτυακή αποτυχία.
-- 4. Τα legacy critical RPCs παύουν να είναι άμεσα εκτελέσιμα από authenticated
--    και χρησιμοποιούνται μόνο εσωτερικά από τα resilient wrappers.
-- 5. Schema version 36.6.6 δηλώνεται μόνο στο τέλος.
-- ============================================================================

begin;

alter table public.unit_requests
  add column if not exists revision bigint not null default 0;

alter table public.unit_requests
  drop constraint if exists unit_requests_revision_nonnegative;
alter table public.unit_requests
  add constraint unit_requests_revision_nonnegative check (revision >= 0);

create table if not exists public.app_operation_idempotency (
  operation_id uuid primary key,
  operation_kind text not null check (char_length(operation_kind) between 1 and 80),
  user_id uuid not null references auth.users(id),
  fingerprint text not null check (char_length(fingerprint)=32),
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  check ((result is null and completed_at is null) or (result is not null and completed_at is not null))
);

create index if not exists app_operation_idempotency_created_idx
  on public.app_operation_idempotency(created_at);

alter table public.app_operation_idempotency enable row level security;
revoke all on table public.app_operation_idempotency from public, anon, authenticated;

create or replace function public.app_operation_fingerprint(p_payload jsonb)
returns text
language sql
immutable
set search_path=public,pg_temp
as $$
  select md5(coalesce(p_payload,'null'::jsonb)::text)
$$;
revoke all on function public.app_operation_fingerprint(jsonb) from public,anon,authenticated;

create or replace function public.app_operation_claim(
  p_operation_id uuid,
  p_operation_kind text,
  p_fingerprint text
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_row public.app_operation_idempotency%rowtype;
  v_uid uuid:=auth.uid();
begin
  if v_uid is null then
    raise exception using errcode='42501',message='Απαιτείται ενεργή συνεδρία χρήστη.';
  end if;
  if p_operation_id is null then
    raise exception 'Λείπει το αναγνωριστικό ασφαλούς επανάληψης της ενέργειας.';
  end if;
  if nullif(btrim(coalesce(p_operation_kind,'')),'') is null
     or p_fingerprint is null or char_length(p_fingerprint)<>32 then
    raise exception 'Μη έγκυρα στοιχεία idempotency.';
  end if;

  insert into public.app_operation_idempotency(operation_id,operation_kind,user_id,fingerprint)
  values(p_operation_id,btrim(p_operation_kind),v_uid,p_fingerprint)
  on conflict(operation_id) do nothing;

  select * into v_row
  from public.app_operation_idempotency x
  where x.operation_id=p_operation_id
  for update;

  if v_row.operation_id is null then
    raise exception 'Δεν ήταν δυνατή η δέσμευση της ενέργειας.';
  end if;
  if v_row.user_id<>v_uid
     or v_row.operation_kind<>btrim(p_operation_kind)
     or v_row.fingerprint<>p_fingerprint then
    raise exception using
      errcode='22023',
      message='Το ίδιο operation_id χρησιμοποιήθηκε για διαφορετική ενέργεια ή διαφορετικά δεδομένα.';
  end if;

  return v_row.result;
end;
$$;
revoke all on function public.app_operation_claim(uuid,text,text) from public,anon,authenticated;

create or replace function public.app_operation_complete(
  p_operation_id uuid,
  p_result jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_uid uuid:=auth.uid();
begin
  if p_result is null then
    raise exception 'Δεν ολοκληρώνεται idempotent ενέργεια χωρίς αποτέλεσμα.';
  end if;
  update public.app_operation_idempotency x
  set result=p_result,completed_at=now()
  where x.operation_id=p_operation_id and x.user_id=v_uid;
  if not found then
    raise exception using errcode='42501',message='Δεν βρέθηκε δεσμευμένη ενέργεια για τον τρέχοντα χρήστη.';
  end if;
  return p_result;
end;
$$;
revoke all on function public.app_operation_complete(uuid,jsonb) from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- Resilient save request: idempotency + optimistic revision.
-- ---------------------------------------------------------------------------
create or replace function public.save_unit_request_resilient_atomic(
  p_operation_id uuid,
  p_expected_revision bigint,
  p_request_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_title text,
  p_action text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
  v_request_id public.unit_requests.id%type;
  v_revision bigint;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'request_id',p_request_id,'municipal_unit_id',p_municipal_unit_id,'group_id',p_group_id,
    'request_year',p_request_year,'title',p_title,'action',p_action,'lines',p_lines,
    'expected_revision',p_expected_revision
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'save_unit_request',v_fp);
  if v_replay is not null then return v_replay; end if;

  -- Lock a stable parent row so two first-time inserts for the same unit cannot race.
  perform u.id from public.municipal_units u
  where u.id::bigint=p_municipal_unit_id for update;

  if nullif(p_request_id,'') is not null then
    select r.id,r.revision into v_request_id,v_revision
    from public.unit_requests r
    where r.id::text=p_request_id
      and r.municipal_unit_id::bigint=p_municipal_unit_id
      and r.group_id::bigint=p_group_id
      and r.request_year=p_request_year
    for update;
  else
    select r.id,r.revision into v_request_id,v_revision
    from public.unit_requests r
    where r.municipal_unit_id::bigint=p_municipal_unit_id
      and r.group_id::bigint=p_group_id
      and r.request_year=p_request_year
    for update;
  end if;

  if v_request_id is null then
    if coalesce(p_expected_revision,0)<>0 then
      raise exception using errcode='40001',message='Το πρόχειρο δημιουργήθηκε ή άλλαξε από άλλο χρήστη. Ανανεώστε πριν αποθηκεύσετε.';
    end if;
  elsif p_expected_revision is null or p_expected_revision<>v_revision then
    raise exception using errcode='40001',message=format(
      'Το πρόχειρο άλλαξε από άλλο χρήστη. Δική σας έκδοση: %s, τρέχουσα έκδοση: %s. Ανανεώστε πριν αποθηκεύσετε.',
      coalesce(p_expected_revision,-1),v_revision
    );
  end if;

  v_result:=public.save_unit_request_atomic(
    p_request_id,p_municipal_unit_id,p_group_id,p_request_year,p_title,p_action,p_lines
  );

  update public.unit_requests r
  set revision=r.revision+1
  where r.id::text=v_result->>'request_id'
  returning revision into v_revision;

  v_result:=v_result||jsonb_build_object('revision',v_revision,'replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.save_unit_request_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,jsonb)
  from public,anon;
grant execute on function public.save_unit_request_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Resilient lock study: stale browser state cannot overwrite a newer draft,
-- and repeating the same operation_id returns the same locked study.
-- ---------------------------------------------------------------------------
create or replace function public.lock_study_resilient_atomic(
  p_operation_id uuid,
  p_expected_revision bigint,
  p_request_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_label text,
  p_supplier_name text,
  p_kimdis_url text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
  v_request_id public.unit_requests.id%type;
  v_revision bigint;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'request_id',p_request_id,'municipal_unit_id',p_municipal_unit_id,'group_id',p_group_id,
    'request_year',p_request_year,'label',p_label,'supplier_name',p_supplier_name,
    'kimdis_url',p_kimdis_url,'lines',p_lines,'expected_revision',p_expected_revision
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'lock_study',v_fp);
  if v_replay is not null then return v_replay; end if;

  perform u.id from public.municipal_units u
  where u.id::bigint=p_municipal_unit_id for update;

  if nullif(p_request_id,'') is not null then
    select r.id,r.revision into v_request_id,v_revision
    from public.unit_requests r
    where r.id::text=p_request_id
      and r.municipal_unit_id::bigint=p_municipal_unit_id
      and r.group_id::bigint=p_group_id
      and r.request_year=p_request_year
    for update;
  else
    select r.id,r.revision into v_request_id,v_revision
    from public.unit_requests r
    where r.municipal_unit_id::bigint=p_municipal_unit_id
      and r.group_id::bigint=p_group_id
      and r.request_year=p_request_year
    for update;
  end if;

  if v_request_id is null then
    if coalesce(p_expected_revision,0)<>0 then
      raise exception using errcode='40001',message='Το πρόχειρο άλλαξε πριν από το κλείδωμα. Ανανεώστε και ελέγξτε ξανά.';
    end if;
  elsif p_expected_revision is null or p_expected_revision<>v_revision then
    raise exception using errcode='40001',message='Το πρόχειρο άλλαξε από άλλο χρήστη πριν από το κλείδωμα. Η μελέτη δεν κλειδώθηκε.';
  end if;

  v_result:=public.lock_study_atomic(
    p_request_id,p_municipal_unit_id,p_group_id,p_request_year,p_label,p_supplier_name,p_kimdis_url,p_lines
  );

  update public.unit_requests r
  set revision=r.revision+1
  where r.id::text=v_result->>'request_id'
  returning revision into v_revision;

  v_result:=v_result||jsonb_build_object('revision',v_revision,'replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.lock_study_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,text,jsonb)
  from public,anon;
grant execute on function public.lock_study_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,text,jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Resilient contract creation/pricing.
-- ---------------------------------------------------------------------------
create or replace function public.save_contract_pricing_resilient_atomic(
  p_operation_id uuid,
  p_contract_id text,
  p_study_id text,
  p_supplier_id text,
  p_title text,
  p_adam text,
  p_protocol_no text,
  p_start_date date,
  p_end_date date,
  p_vat_rate numeric,
  p_pricing_mode text,
  p_discount_pct numeric,
  p_item_prices jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'contract_id',p_contract_id,'study_id',p_study_id,'supplier_id',p_supplier_id,'title',p_title,
    'adam',p_adam,'protocol_no',p_protocol_no,'start_date',p_start_date,'end_date',p_end_date,
    'vat_rate',p_vat_rate,'pricing_mode',p_pricing_mode,'discount_pct',p_discount_pct,'item_prices',p_item_prices
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'save_contract_pricing',v_fp);
  if v_replay is not null then return v_replay; end if;

  v_result:=public.save_contract_pricing_atomic(
    p_contract_id,p_study_id,p_supplier_id,p_title,p_adam,p_protocol_no,
    p_start_date,p_end_date,p_vat_rate,p_pricing_mode,p_discount_pct,p_item_prices
  );
  v_result:=v_result||jsonb_build_object('replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.save_contract_pricing_resilient_atomic(uuid,text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)
  from public,anon;
grant execute on function public.save_contract_pricing_resilient_atomic(uuid,text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Resilient order save/issue.
-- ---------------------------------------------------------------------------
create or replace function public.save_order_resilient_atomic(
  p_operation_id uuid,
  p_order_id text,
  p_study_id text,
  p_order_date date,
  p_receiver_id text,
  p_usage_location text,
  p_notes text,
  p_vat_rate numeric,
  p_items jsonb,
  p_issue boolean
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'order_id',p_order_id,'study_id',p_study_id,'order_date',p_order_date,
    'receiver_id',p_receiver_id,'usage_location',p_usage_location,'notes',p_notes,
    'vat_rate',p_vat_rate,'items',p_items,'issue',p_issue
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'save_order',v_fp);
  if v_replay is not null then return v_replay; end if;

  v_result:=public.save_order_atomic(
    p_order_id,p_study_id,p_order_date,p_receiver_id,p_usage_location,p_notes,p_vat_rate,p_items,p_issue
  );
  v_result:=v_result||jsonb_build_object('replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.save_order_resilient_atomic(uuid,text,text,date,text,text,text,numeric,jsonb,boolean)
  from public,anon;
grant execute on function public.save_order_resilient_atomic(uuid,text,text,date,text,text,text,numeric,jsonb,boolean)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Resilient secure Excel import: retry after lost response returns the original
-- result instead of reusing a consumed token or reapplying catalog mutations.
-- Also participates in request revision conflict detection.
-- ---------------------------------------------------------------------------
create or replace function public.secure_import_catalog_request_resilient_atomic(
  p_operation_id uuid,
  p_expected_revision bigint,
  p_import_token uuid,
  p_request_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_title text,
  p_material_updates jsonb,
  p_new_materials jsonb,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
  v_request_id public.unit_requests.id%type;
  v_revision bigint;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'import_token',p_import_token,'request_id',p_request_id,'municipal_unit_id',p_municipal_unit_id,
    'group_id',p_group_id,'request_year',p_request_year,'title',p_title,
    'material_updates',p_material_updates,'new_materials',p_new_materials,'lines',p_lines,
    'expected_revision',p_expected_revision
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'secure_excel_import',v_fp);
  if v_replay is not null then return v_replay; end if;

  perform u.id from public.municipal_units u
  where u.id::bigint=p_municipal_unit_id for update;

  if nullif(p_request_id,'') is not null then
    select r.id,r.revision into v_request_id,v_revision
    from public.unit_requests r
    where r.id::text=p_request_id
      and r.municipal_unit_id::bigint=p_municipal_unit_id
      and r.group_id::bigint=p_group_id
      and r.request_year=p_request_year
    for update;
  else
    select r.id,r.revision into v_request_id,v_revision
    from public.unit_requests r
    where r.municipal_unit_id::bigint=p_municipal_unit_id
      and r.group_id::bigint=p_group_id
      and r.request_year=p_request_year
    for update;
  end if;

  if v_request_id is null then
    if coalesce(p_expected_revision,0)<>0 then
      raise exception using errcode='40001',message='Το πρόχειρο άλλαξε πριν από την εισαγωγή Excel. Ανανεώστε και επαναλάβετε.';
    end if;
  elsif p_expected_revision is null or p_expected_revision<>v_revision then
    raise exception using errcode='40001',message='Το πρόχειρο άλλαξε από άλλο χρήστη. Η εισαγωγή Excel δεν εφαρμόστηκε.';
  end if;

  v_result:=public.secure_import_catalog_request_atomic(
    p_import_token,p_request_id,p_municipal_unit_id,p_group_id,p_request_year,p_title,
    p_material_updates,p_new_materials,p_lines
  );

  update public.unit_requests r
  set revision=r.revision+1
  where r.id::text=v_result->>'request_id'
  returning revision into v_revision;

  v_result:=v_result||jsonb_build_object('revision',v_revision,'replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.secure_import_catalog_request_resilient_atomic(uuid,bigint,uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  from public,anon;
grant execute on function public.secure_import_catalog_request_resilient_atomic(uuid,bigint,uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  to authenticated;

-- The browser must use resilient entry points for critical operations.
-- Internal SECURITY DEFINER functions continue to call the legacy implementations.
revoke execute on function public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb) from authenticated;
revoke execute on function public.lock_study_atomic(text,bigint,bigint,integer,text,text,text,jsonb) from authenticated;
revoke execute on function public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean) from authenticated;
revoke execute on function public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb) from authenticated;

create or replace function public.app_schema_version()
returns text
language sql
stable
set search_path=public,pg_temp
as $$ select '36.6.6'::text $$;
revoke all on function public.app_schema_version() from public,anon;
grant execute on function public.app_schema_version() to authenticated;

commit;
