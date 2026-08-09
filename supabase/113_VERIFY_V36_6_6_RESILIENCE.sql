-- ============================================================================
-- 113_VERIFY_V36_6_6_RESILIENCE.sql
-- READ ONLY — Phase 4 production resilience verifier.
-- ============================================================================

with
wrappers as (
  select jsonb_build_object(
    'save_request_resilient',to_regprocedure('public.save_unit_request_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,jsonb)') is not null,
    'lock_study_resilient',to_regprocedure('public.lock_study_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,text,jsonb)') is not null,
    'contract_pricing_resilient',to_regprocedure('public.save_contract_pricing_resilient_atomic(uuid,text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)') is not null,
    'order_resilient',to_regprocedure('public.save_order_resilient_atomic(uuid,text,text,date,text,text,text,numeric,jsonb,boolean)') is not null,
    'excel_import_resilient',to_regprocedure('public.secure_import_catalog_request_resilient_atomic(uuid,bigint,uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)') is not null,
    'copy_request_resilient',to_regprocedure('public.copy_unit_request_resilient_atomic(uuid,bigint,bigint,bigint,bigint,integer,text,jsonb)') is not null,
    'load_template_resilient',to_regprocedure('public.load_study_template_resilient_atomic(uuid,bigint,text,bigint,bigint,integer)') is not null
  ) j
),
legacy_grants as (
  select jsonb_build_object(
    'save_request_legacy_authenticated',has_function_privilege('authenticated','public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)','EXECUTE'),
    'lock_study_legacy_authenticated',has_function_privilege('authenticated','public.lock_study_atomic(text,bigint,bigint,integer,text,text,text,jsonb)','EXECUTE'),
    'save_contract_legacy_authenticated',has_function_privilege('authenticated','public.save_contract_atomic(text,text,text,text,text,text,date,date,numeric)','EXECUTE'),
    'save_contract_pricing_legacy_authenticated',has_function_privilege('authenticated','public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)','EXECUTE'),
    'save_order_legacy_authenticated',has_function_privilege('authenticated','public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean)','EXECUTE'),
    'excel_import_legacy_authenticated',has_function_privilege('authenticated','public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)','EXECUTE'),
    'copy_request_legacy_authenticated',has_function_privilege('authenticated','public.copy_unit_request_atomic(bigint,bigint,bigint,integer,text,jsonb)','EXECUTE'),
    'load_template_legacy_authenticated',has_function_privilege('authenticated','public.load_study_template_atomic(text,bigint,bigint,integer)','EXECUTE')
  ) j
),
idempotency as (
  select jsonb_build_object(
    'table_exists',to_regclass('public.app_operation_idempotency') is not null,
    'rls_enabled',coalesce((select c.relrowsecurity from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='public' and c.relname='app_operation_idempotency'),false),
    'authenticated_direct_select',coalesce(has_table_privilege('authenticated','public.app_operation_idempotency','SELECT'),false),
    'anon_direct_select',coalesce(has_table_privilege('anon','public.app_operation_idempotency','SELECT'),false),
    'rows_total',(select count(*) from public.app_operation_idempotency),
    'incomplete_committed_rows',(select count(*) from public.app_operation_idempotency where result is null or completed_at is null),
    'duplicate_operation_ids',(select count(*) from (select operation_id from public.app_operation_idempotency group by operation_id having count(*)>1) q)
  ) j
),
revision as (
  select jsonb_build_object(
    'revision_column_exists',exists(select 1 from information_schema.columns where table_schema='public' and table_name='unit_requests' and column_name='revision'),
    'negative_revisions',(select count(*) from public.unit_requests where revision<0),
    'requests_total',(select count(*) from public.unit_requests)
  ) j
),
transaction_integrity as (
  select jsonb_build_object(
    'orders_without_study',(select count(*) from public.mo_orders o left join public.locked_studies s on s.id=o.study_id where s.id is null),
    'order_items_without_order',(select count(*) from public.mo_order_items i left join public.mo_orders o on o.id=i.order_id where o.id is null),
    'contract_items_without_contract',(select count(*) from public.mo_contract_items i left join public.mo_contracts c on c.id=i.contract_id where c.id is null),
    'contracts_without_study',(select count(*) from public.mo_contracts c left join public.locked_studies s on s.id=c.source_study_id where s.id is null),
    'duplicate_contract_per_study',(select count(*) from (select source_study_id from public.mo_contracts group by source_study_id having count(*)>1) q),
    'duplicate_order_numbers',(select count(*) from (select order_no from public.mo_orders where order_no is not null group by order_no having count(*)>1) q),
    'duplicate_request_context',(select count(*) from (select municipal_unit_id,group_id,request_year from public.unit_requests group by 1,2,3 having count(*)>1) q)
  ) j
),
excel as (
  select jsonb_build_object(
    'unused_expired_tokens',(select count(*) from public.app_excel_import_tokens where used_at is null and expires_at<=now()),
    'used_token_consistency_errors',(select count(*) from public.app_excel_import_tokens where (used_at is null)<>(used_by is null) or (used_at is null)<>(used_request_id is null)),
    'tokens_total',(select count(*) from public.app_excel_import_tokens)
  ) j
),
checks as (
  select jsonb_build_object(
    'schema_is_36_6_6',public.app_schema_version()='36.6.6',
    'all_resilient_wrappers_exist',(select bool_and((value)::boolean) from wrappers,jsonb_each_text(wrappers.j)),
    'legacy_critical_rpc_blocked',not (select bool_or((value)::boolean) from legacy_grants,jsonb_each_text(legacy_grants.j)),
    'idempotency_rls_on',(idempotency.j->>'rls_enabled')::boolean,
    'idempotency_not_directly_readable',not (idempotency.j->>'authenticated_direct_select')::boolean and not (idempotency.j->>'anon_direct_select')::boolean,
    'no_incomplete_idempotency',(idempotency.j->>'incomplete_committed_rows')::bigint=0,
    'revision_column_present',(revision.j->>'revision_column_exists')::boolean,
    'no_negative_revisions',(revision.j->>'negative_revisions')::bigint=0,
    'transaction_integrity_clean',(select bool_and((value)::bigint=0) from transaction_integrity,jsonb_each_text(transaction_integrity.j)),
    'excel_token_consistency_clean',(excel.j->>'used_token_consistency_errors')::bigint=0
  ) j
  from idempotency,revision,transaction_integrity,excel
)
select jsonb_pretty(jsonb_build_object(
  'verified_at',clock_timestamp(),
  'schema_version',public.app_schema_version(),
  'phase4_db_ready',(select bool_and((value)::boolean) from checks,jsonb_each_text(checks.j)),
  'checks',(select j from checks),
  'wrappers',(select j from wrappers),
  'legacy_grants',(select j from legacy_grants),
  'idempotency',(select j from idempotency),
  'revision',(select j from revision),
  'transaction_integrity',(select j from transaction_integrity),
  'excel',(select j from excel)
)) as v36_6_6_resilience_verification;
