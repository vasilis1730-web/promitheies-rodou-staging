-- ==========================================================================
-- 108_VERIFY_V36_6_4.sql — READ ONLY
-- Επιστρέφει μία JSON εγγραφή. Δεν εκτελεί DML/DDL.
-- ==========================================================================

with
privileges as (
  select
    has_function_privilege(
      'authenticated',
      'public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)',
      'EXECUTE'
    ) as legacy_import_authenticated_execute,
    has_function_privilege(
      'authenticated',
      'public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)',
      'EXECUTE'
    ) as secure_import_authenticated_execute
),
triggers as (
  select
    exists (
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='mo_orders'
        and t.tgname='trg_mo_orders_contract_integrity' and not t.tgisinternal and t.tgenabled<>'D'
    ) as order_contract_integrity,
    exists (
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='locked_studies'
        and t.tgname='trg_locked_studies_contract_cancel_guard' and not t.tgisinternal and t.tgenabled<>'D'
    ) as study_contract_cancel_guard,
    exists (
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='mo_contracts'
        and t.tgname='trg_mo_contracts_order_history_guard' and not t.tgisinternal and t.tgenabled<>'D'
    ) as contract_order_history_guard,
    exists (
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='request_lines'
        and t.tgname='trg_request_lines_catalog_guard' and not t.tgisinternal and t.tgenabled<>'D'
    ) as request_line_catalog_guard
),
violations as (
  select
    (select count(*) from public.locked_studies s join public.mo_contracts c on c.source_study_id=s.id
      where s.record_status='cancelled')::int as cancelled_studies_with_contract,
    (select count(*) from public.mo_orders o join public.mo_contracts c on c.id=o.contract_id
      where o.status in ('issued','sent','received') and o.vat_rate is distinct from c.vat_rate)::int as order_vat_rate_mismatch,
    (select count(*) from public.mo_orders o join public.mo_contracts c on c.id=o.contract_id
      where o.status in ('issued','sent','received') and (
        o.vat is distinct from round(coalesce(o.subtotal,0)*c.vat_rate/100,2)
        or o.total is distinct from round(coalesce(o.subtotal,0)+round(coalesce(o.subtotal,0)*c.vat_rate/100,2),2)
      ))::int as order_totals_mismatch,
    (select count(*) from public.mo_orders o join public.mo_contracts c on c.id=o.contract_id
      where o.status in ('issued','sent','received') and (
        o.order_date is null
        or (c.start_date is not null and o.order_date<c.start_date)
        or (c.end_date is not null and o.order_date>c.end_date)
      ))::int as orders_outside_contract_dates,
    (select count(*) from public.mo_orders o join public.mo_contracts c on c.id=o.contract_id
      where o.status in ('issued','sent','received') and o.supplier_id is distinct from c.supplier_id)::int as order_supplier_mismatch,
    (select count(*) from public.mo_orders o join public.mo_contracts c on c.id=o.contract_id
      where o.status in ('issued','sent') and coalesce(c.active,true) is not true)::int as open_orders_on_inactive_contract,
    (select count(*) from public.request_lines rl join public.materials m on m.id=rl.material_id
      where m.is_active is not true)::int as current_request_lines_on_inactive_catalog_items
),
catalog as (
  select
    count(*) filter (where g.domain='procurement' and m.is_active)::int as procurement_items,
    count(*) filter (where g.domain='service' and m.is_active)::int as service_items,
    count(*) filter (where g.domain='procurement' and m.is_active and coalesce(trim(m.technical_specs),'')='')::int as procurement_missing_specs,
    count(*) filter (where g.domain='service' and m.is_active and coalesce(trim(m.technical_specs),'')='')::int as service_missing_specs
  from public.materials m join public.procurement_groups g on g.id=m.group_id
),
authz as (
  select
    coalesce((select position('is_active' in lower(p.prosrc))>0 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='app_current_role' and pg_get_function_identity_arguments(p.oid)='' limit 1),false) as current_role_checks_active,
    coalesce((select position('is_active' in lower(p.prosrc))>0 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname='app_current_unit_id' and pg_get_function_identity_arguments(p.oid)='' limit 1),false) as current_unit_checks_active
)
select jsonb_pretty(jsonb_build_object(
  'verified_at',now(),
  'schema_version',public.app_schema_version(),
  'authorization',to_jsonb(authz),
  'privileges',to_jsonb(privileges),
  'triggers',to_jsonb(triggers),
  'violations',to_jsonb(violations),
  'catalog',to_jsonb(catalog),
  'expected',jsonb_build_object(
    'schema_version','36.6.4',
    'legacy_import_authenticated_execute',false,
    'secure_import_authenticated_execute',true,
    'all_four_integrity_triggers',true,
    'all_violation_counts_except_inactive_working_lines',0,
    'procurement_missing_specs',0,
    'service_missing_specs',0
  )
)) as v36_6_4_verification
from privileges,triggers,violations,catalog,authz;
