-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΦΑΣΗ 5
-- VERIFY RLS / PRIVILEGE HARDENING (READ-ONLY)
--
-- Εκτελείται ΜΕΤΑ την 202608090008_phase5_rls_privilege_hardening.sql.
-- Δεν μεταβάλλει δεδομένα, policies ή privileges.
-- ============================================================================

with
public_tables as (
  select c.oid,c.relname,c.relrowsecurity
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('r','p')
),
public_views as (
  select c.oid,c.relname,c.relkind,
         coalesce(c.reloptions,'{}'::text[]) @> array['security_invoker=true'] as security_invoker
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('v','m')
),
public_functions as (
  select
    p.oid,
    format('%I.%I(%s)','public',p.proname,pg_get_function_identity_arguments(p.oid)) as signature,
    p.prosecdef as security_definer,
    (
      select regexp_replace(cfg,'^search_path=','')
      from unnest(coalesce(p.proconfig,array[]::text[])) cfg
      where cfg like 'search_path=%'
      limit 1
    ) as configured_search_path,
    has_function_privilege('anon',p.oid,'EXECUTE') as anon_execute,
    has_function_privilege('authenticated',p.oid,'EXECUTE') as auth_execute,
    exists (
      select 1
      from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
      where a.grantee=0 and a.privilege_type='EXECUTE'
    ) as public_execute
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind in ('f','p')
),
postgres_public_default_acl_risks as (
  select
    case d.defaclobjtype
      when 'r' then 'TABLES'
      when 'S' then 'SEQUENCES'
      when 'f' then 'FUNCTIONS'
      else d.defaclobjtype::text
    end as object_type,
    case when a.grantee=0 then 'PUBLIC' else r.rolname end as grantee,
    a.privilege_type
  from pg_default_acl d
  join pg_roles owner_role on owner_role.oid=d.defaclrole
  left join pg_namespace n on n.oid=d.defaclnamespace
  cross join lateral aclexplode(d.defaclacl) a
  left join pg_roles r on r.oid=a.grantee
  where owner_role.rolname='postgres'
    and n.nspname='public'
    and (a.grantee=0 or r.rolname in ('anon','authenticated'))
    and (
      (d.defaclobjtype='f' and a.privilege_type='EXECUTE')
      or (d.defaclobjtype='r' and a.privilege_type in ('SELECT','INSERT','UPDATE','DELETE','TRUNCATE','REFERENCES','TRIGGER','MAINTAIN'))
      or (d.defaclobjtype='S' and a.privilege_type in ('SELECT','UPDATE','USAGE'))
    )
),
policy_flags as (
  select c.relname as table_name,p.polname as policy_name,
         coalesce(lower(btrim(pg_get_expr(p.polqual,p.polrelid))),'') in ('true','(true)') as using_true
  from pg_policy p
  join pg_class c on c.oid=p.polrelid
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
),
checks as (
  select jsonb_build_object(
    'schema_still_36_6_6', public.app_schema_version()='36.6.6',
    'all_public_tables_have_rls', not exists(select 1 from public_tables where not relrowsecurity),
    'anon_has_no_public_table_access', not exists(
      select 1 from public_tables t
      where has_table_privilege('anon',t.oid,'SELECT')
         or has_table_privilege('anon',t.oid,'INSERT')
         or has_table_privilege('anon',t.oid,'UPDATE')
         or has_table_privilege('anon',t.oid,'DELETE')
    ),
    'public_function_execute_is_zero', not exists(select 1 from public_functions where public_execute),
    'anon_function_execute_is_zero', not exists(select 1 from public_functions where anon_execute),
    'anon_security_definer_execute_is_zero', not exists(
      select 1 from public_functions where anon_execute and security_definer
    ),
    'security_definers_have_search_path', not exists(
      select 1 from public_functions where security_definer and configured_search_path is null
    ),
    'exposed_views_are_security_invoker', not exists(
      select 1 from public_views
      where relkind='v' and has_table_privilege('authenticated',oid,'SELECT') and not security_invoker
    ),
    'browser_roles_cannot_create_in_public',
      not has_schema_privilege('anon','public','CREATE')
      and not has_schema_privilege('authenticated','public','CREATE'),
    'postgres_future_app_defaults_are_opt_in', not exists(select 1 from postgres_public_default_acl_risks),
    'legacy_mo_projects_blocked', case
      when to_regclass('public.mo_projects') is null then true
      else not (
        has_table_privilege('authenticated','public.mo_projects','SELECT')
        or has_table_privilege('authenticated','public.mo_projects','INSERT')
        or has_table_privilege('authenticated','public.mo_projects','UPDATE')
        or has_table_privilege('authenticated','public.mo_projects','DELETE')
      ) end,
    'legacy_mo_counters_blocked', case
      when to_regclass('public.mo_counters') is null then true
      else not (
        has_table_privilege('authenticated','public.mo_counters','SELECT')
        or has_table_privilege('authenticated','public.mo_counters','INSERT')
        or has_table_privilege('authenticated','public.mo_counters','UPDATE')
        or has_table_privilege('authenticated','public.mo_counters','DELETE')
      ) end,
    'legacy_true_policies_removed', not exists(
      select 1 from policy_flags
      where (table_name='mo_projects' and policy_name in ('mo_projects_select','mo_projects_manage'))
         or (table_name='mo_counters' and policy_name='mo_counters_select')
    ),
    'idempotency_direct_read_blocked',
      not has_table_privilege('anon','public.app_operation_idempotency','SELECT')
      and not has_table_privilege('authenticated','public.app_operation_idempotency','SELECT'),
    'resilient_save_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.save_unit_request_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,jsonb)'),'EXECUTE'),false),
    'resilient_lock_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.lock_study_resilient_atomic(uuid,bigint,text,bigint,bigint,integer,text,text,text,jsonb)'),'EXECUTE'),false),
    'resilient_contract_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.save_contract_pricing_resilient_atomic(uuid,text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)'),'EXECUTE'),false),
    'resilient_order_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.save_order_resilient_atomic(uuid,text,text,date,text,text,text,numeric,jsonb,boolean)'),'EXECUTE'),false),
    'resilient_excel_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.secure_import_catalog_request_resilient_atomic(uuid,bigint,uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)'),'EXECUTE'),false),
    'resilient_copy_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.copy_unit_request_resilient_atomic(uuid,bigint,bigint,bigint,bigint,integer,text,jsonb)'),'EXECUTE'),false),
    'resilient_template_load_still_callable', coalesce(has_function_privilege(
      'authenticated',to_regprocedure('public.load_study_template_resilient_atomic(uuid,bigint,text,bigint,bigint,integer)'),'EXECUTE'),false)
  ) as j
),
counts as (
  select jsonb_build_object(
    'public_tables',(select count(*) from public_tables),
    'rls_disabled',(select count(*) from public_tables where not relrowsecurity),
    'public_execute_functions',(select count(*) from public_functions where public_execute),
    'anon_execute_functions',(select count(*) from public_functions where anon_execute),
    'anon_security_definer_functions',(select count(*) from public_functions where anon_execute and security_definer),
    'security_definer_without_search_path',(select count(*) from public_functions where security_definer and configured_search_path is null),
    'postgres_public_default_acl_risks',(select count(*) from postgres_public_default_acl_risks),
    'unconditional_true_policies',(select count(*) from policy_flags where using_true)
  ) as j
),
final as (
  select
    (select j from checks) as c,
    (select j from counts) as n
)
select jsonb_pretty(jsonb_build_object(
  'audit','PHASE5_RLS_PRIVILEGE_HARDENING_VERIFY',
  'verified_at',clock_timestamp(),
  'schema_version',public.app_schema_version(),
  'checks',c,
  'counts',n,
  'phase5_privilege_hardening_ready',
    not exists (
      select 1 from jsonb_each(c) e
      where e.value <> 'true'::jsonb
    ),
  'supplier_receiver_privacy_review',jsonb_build_object(
    'status','BUSINESS_POLICY_REVIEW',
    'mo_suppliers_authenticated_select',has_table_privilege('authenticated','public.mo_suppliers','SELECT'),
    'mo_receivers_authenticated_select',has_table_privilege('authenticated','public.mo_receivers','SELECT'),
    'note','Οι κοινόχρηστοι κατάλογοι παραμένουν λειτουργικά αμετάβλητοι σε αυτή τη migration. Η απόφαση shared-vs-unit-scoped είναι ξεχωριστή πολιτική απορρήτου.'
  ),
  'postgres_default_acl_remaining',coalesce((
    select jsonb_agg(jsonb_build_object('object_type',object_type,'grantee',grantee,'privilege',privilege_type))
    from postgres_public_default_acl_risks
  ),'[]'::jsonb)
)) as phase5_privilege_verification
from final;
