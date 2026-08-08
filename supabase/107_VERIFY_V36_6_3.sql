-- ==========================================================================
-- 107_VERIFY_V36_6_3.sql
-- Read-only post-migration verification for v36.6.3.
-- Δεν εκτελεί DML/DDL. Επιστρέφει μία JSON εγγραφή.
-- ==========================================================================

with
fn as (
  select
    to_regprocedure('public.app_user_is_active()') is not null as app_user_is_active_exists,
    coalesce((select position('is_active' in lower(p.prosrc)) > 0
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='app_current_role'
                and pg_get_function_identity_arguments(p.oid)=''
              limit 1), false) as current_role_checks_is_active,
    coalesce((select position('is_active' in lower(p.prosrc)) > 0
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='app_current_unit_id'
                and pg_get_function_identity_arguments(p.oid)=''
              limit 1), false) as current_unit_checks_is_active,
    coalesce((select position('app_user_is_active' in lower(p.prosrc)) > 0
              from pg_proc p join pg_namespace n on n.oid=p.pronamespace
              where n.nspname='public' and p.proname='app_can_supervise'
                and pg_get_function_identity_arguments(p.oid)=''
              limit 1), false) as can_supervise_checks_active
),
rls_tables as (
  select c.relname as table_name
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relkind in ('r','p')
    and c.relrowsecurity
),
guards as (
  select
    (select count(*) from rls_tables)::int as rls_table_count,
    (select count(*) from rls_tables r
       where not exists (
         select 1 from pg_policies p
         where p.schemaname='public'
           and p.tablename=r.table_name
           and p.policyname='app_active_user_guard'
           and lower(p.permissive)='restrictive'
       ))::int as rls_tables_missing_active_guard
),
anon_view_grants as (
  select coalesce(jsonb_agg(jsonb_build_object(
    'view', table_name, 'privilege', privilege_type
  ) order by table_name, privilege_type), '[]'::jsonb) as rows
  from information_schema.role_table_grants
  where table_schema='public'
    and grantee='anon'
    and table_name in ('v_materials_with_price','v_request_lines_detailed','v_request_totals')
),
security_checks as (
  select
    (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind='r' and not c.relrowsecurity)::int
      as public_tables_without_rls,
    (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prosecdef
        and has_function_privilege('anon', p.oid, 'EXECUTE'))::int
      as anon_executable_security_definer_functions
),
catalog as (
  select
    count(*) filter (where g.domain='procurement' and m.is_active)::int as procurement_items,
    count(*) filter (where g.domain='service' and m.is_active)::int as service_items,
    count(*) filter (where g.domain='procurement' and m.is_active
      and coalesce(trim(m.technical_specs),'')='')::int as procurement_missing_specs,
    count(*) filter (where g.domain='service' and m.is_active
      and coalesce(trim(m.technical_specs),'')='')::int as service_missing_specs
  from public.materials m
  join public.procurement_groups g on g.id=m.group_id
),
integrity as (
  select
    (select count(*) from public.mo_orders o
      where o.study_id is not null and not exists (
        select 1 from public.locked_studies s where s.id::text=o.study_id::text
      ))::int as orders_without_study,
    (select count(*) from public.mo_order_items i
      where not exists (select 1 from public.mo_orders o where o.id=i.order_id))::int
      as order_items_without_order,
    (select count(*) from public.mo_contract_items i
      where not exists (select 1 from public.mo_contracts c where c.id=i.contract_id))::int
      as contract_items_without_contract
)
select jsonb_pretty(jsonb_build_object(
  'verified_at', now(),
  'schema_version', public.app_schema_version(),
  'authorization', jsonb_build_object(
    'app_user_is_active_exists', fn.app_user_is_active_exists,
    'current_role_checks_is_active', fn.current_role_checks_is_active,
    'current_unit_checks_is_active', fn.current_unit_checks_is_active,
    'can_supervise_checks_active', fn.can_supervise_checks_active
  ),
  'rls', jsonb_build_object(
    'rls_table_count', guards.rls_table_count,
    'rls_tables_missing_active_guard', guards.rls_tables_missing_active_guard,
    'public_tables_without_rls', security_checks.public_tables_without_rls
  ),
  'security', jsonb_build_object(
    'anon_executable_security_definer_functions', security_checks.anon_executable_security_definer_functions,
    'anon_diagnostic_view_grants', anon_view_grants.rows
  ),
  'catalog', to_jsonb(catalog),
  'integrity', to_jsonb(integrity),
  'expected', jsonb_build_object(
    'schema_version','36.6.3',
    'rls_tables_missing_active_guard',0,
    'public_tables_without_rls',0,
    'anon_executable_security_definer_functions',0,
    'procurement_missing_specs',0,
    'service_missing_specs',0
  )
)) as v36_6_3_verification
from fn, guards, anon_view_grants, security_checks, catalog, integrity;
