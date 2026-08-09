-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΦΑΣΗ 5
-- ΠΛΗΡΕΣ SUPABASE RLS / PRIVILEGE AUDIT (READ-ONLY)
--
-- Στόχος:
--   Inventory της ΠΡΑΓΜΑΤΙΚΗΣ staging βάσης v36.6.6 από pg_catalog.
--   ΔΕΝ κάνει CREATE/ALTER/GRANT/REVOKE/INSERT/UPDATE/DELETE.
--
-- Εκτέλεση:
--   Supabase Dashboard -> SQL Editor -> New query -> Run.
--   Στείλτε ολόκληρο το JSON της στήλης phase5_security_audit.
-- ============================================================================

with
public_tables as (
  select
    c.oid,
    c.relname as table_name,
    c.relrowsecurity as rls_enabled,
    c.relforcerowsecurity as force_rls,
    pg_get_userbyid(c.relowner) as owner_name,
    has_table_privilege('anon', c.oid, 'SELECT') as anon_select,
    has_table_privilege('anon', c.oid, 'INSERT') as anon_insert,
    has_table_privilege('anon', c.oid, 'UPDATE') as anon_update,
    has_table_privilege('anon', c.oid, 'DELETE') as anon_delete,
    has_table_privilege('authenticated', c.oid, 'SELECT') as auth_select,
    has_table_privilege('authenticated', c.oid, 'INSERT') as auth_insert,
    has_table_privilege('authenticated', c.oid, 'UPDATE') as auth_update,
    has_table_privilege('authenticated', c.oid, 'DELETE') as auth_delete,
    (select count(*) from pg_policy p where p.polrelid=c.oid) as policy_count
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relkind in ('r','p')
),
policy_details as (
  select
    c.relname as table_name,
    p.polname as policy_name,
    case p.polcmd
      when '*' then 'ALL'
      when 'r' then 'SELECT'
      when 'a' then 'INSERT'
      when 'w' then 'UPDATE'
      when 'd' then 'DELETE'
      else p.polcmd::text
    end as command,
    p.polpermissive as permissive,
    (
      select coalesce(jsonb_agg(x.role_name order by x.role_name),'[]'::jsonb)
      from (
        select case
          when role_oid=0 then 'PUBLIC'
          else coalesce((select r.rolname from pg_roles r where r.oid=role_oid), role_oid::text)
        end as role_name
        from unnest(p.polroles) as role_oid
      ) x
    ) as roles,
    pg_get_expr(p.polqual,p.polrelid) as using_expression,
    pg_get_expr(p.polwithcheck,p.polrelid) as check_expression,
    (
      coalesce(lower(btrim(pg_get_expr(p.polqual,p.polrelid))),'') in ('true','(true)')
      or coalesce(lower(btrim(pg_get_expr(p.polwithcheck,p.polrelid))),'') in ('true','(true)')
    ) as unconditional_true
  from pg_policy p
  join pg_class c on c.oid=p.polrelid
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
),
public_views as (
  select
    c.oid,
    c.relname as view_name,
    case c.relkind when 'v' then 'view' when 'm' then 'materialized_view' else c.relkind::text end as view_type,
    coalesce(c.reloptions,'{}'::text[]) @> array['security_invoker=true'] as security_invoker,
    has_table_privilege('anon', c.oid, 'SELECT') as anon_select,
    has_table_privilege('authenticated', c.oid, 'SELECT') as auth_select
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('v','m')
),
function_base as (
  select
    p.oid,
    p.proname,
    pg_get_function_identity_arguments(p.oid) as identity_args,
    format('%I.%I(%s)','public',p.proname,pg_get_function_identity_arguments(p.oid)) as signature,
    p.prosecdef as security_definer,
    pg_get_userbyid(p.proowner) as owner_name,
    p.prorettype='pg_catalog.trigger'::regtype as returns_trigger,
    (
      select regexp_replace(cfg,'^search_path=','')
      from unnest(coalesce(p.proconfig,array[]::text[])) cfg
      where cfg like 'search_path=%'
      limit 1
    ) as configured_search_path,
    coalesce(array_to_string(p.proconfig,','),'') like '%row_security=off%' as row_security_off,
    has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
    has_function_privilege('authenticated', p.oid, 'EXECUTE') as auth_execute
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.prokind in ('f','p')
),
function_acl as (
  select p.oid as function_oid,a.grantee,a.privilege_type
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  cross join lateral aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
  where n.nspname='public'
),
public_functions as (
  select f.*,
    exists (
      select 1 from function_acl a
      where a.function_oid=f.oid and a.grantee=0 and a.privilege_type='EXECUTE'
    ) as public_execute
  from function_base f
),
schema_acl as (
  select a.grantee,a.privilege_type
  from pg_namespace n
  cross join lateral aclexplode(coalesce(n.nspacl,acldefault('n',n.nspowner))) a
  where n.nspname='public'
),
client_roles as (
  select rolname,rolbypassrls,rolsuper
  from pg_roles
  where rolname in ('anon','authenticated')
),
default_acl_exposure as (
  select
    pg_get_userbyid(d.defaclrole) as owner_name,
    coalesce(n.nspname,'*') as schema_name,
    case d.defaclobjtype
      when 'r' then 'TABLES'
      when 'S' then 'SEQUENCES'
      when 'f' then 'FUNCTIONS'
      when 'T' then 'TYPES'
      when 'n' then 'SCHEMAS'
      else d.defaclobjtype::text
    end as object_type,
    case when a.grantee=0 then 'PUBLIC'
      else coalesce((select r.rolname from pg_roles r where r.oid=a.grantee),a.grantee::text)
    end as grantee,
    a.privilege_type
  from pg_default_acl d
  left join pg_namespace n on n.oid=d.defaclnamespace
  cross join lateral aclexplode(d.defaclacl) a
  where a.grantee=0 or exists (
    select 1 from pg_roles r where r.oid=a.grantee and r.rolname in ('anon','authenticated')
  )
),
public_extensions as (
  select e.extname as extension_name
  from pg_extension e join pg_namespace n on n.oid=e.extnamespace
  where n.nspname='public'
),
public_foreign_tables as (
  select c.relname as table_name
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='f'
),
sensitive_columns as (
  select c.table_name,c.column_name,t.anon_select,t.auth_select
  from information_schema.columns c
  join public_tables t on t.table_name=c.table_name
  where c.table_schema='public'
    and c.column_name ~* '(password|passwd|secret|token|api_?key|service_?key|private_?key|email|phone|mobile|iban|afm|tax_?id|address)'
),
realtime_publications as (
  select schemaname,tablename,pubname
  from pg_publication_tables
  where schemaname='public'
),
summary as (
  select jsonb_build_object(
    'schema_version',case when to_regprocedure('public.app_schema_version()') is not null then public.app_schema_version() else null end,
    'public_table_count',(select count(*) from public_tables),
    'rls_disabled_count',(select count(*) from public_tables where not rls_enabled),
    'rls_enabled_without_policy_count',(select count(*) from public_tables where rls_enabled and policy_count=0),
    'anon_table_access_count',(select count(*) from public_tables where anon_select or anon_insert or anon_update or anon_delete),
    'authenticated_direct_write_table_count',(select count(*) from public_tables where auth_insert or auth_update or auth_delete),
    'unconditional_true_policy_count',(select count(*) from policy_details where unconditional_true),
    'public_function_count',(select count(*) from public_functions),
    'public_execute_function_count',(select count(*) from public_functions where public_execute),
    'anon_executable_function_count',(select count(*) from public_functions where anon_execute),
    'anon_executable_security_definer_count',(select count(*) from public_functions where anon_execute and security_definer),
    'authenticated_executable_security_definer_count',(select count(*) from public_functions where auth_execute and security_definer),
    'security_definer_without_search_path_count',(select count(*) from public_functions where security_definer and configured_search_path is null),
    'auth_security_definer_row_security_off_count',(select count(*) from public_functions where auth_execute and security_definer and row_security_off),
    'exposed_non_invoker_view_count',(select count(*) from public_views where view_type='view' and not security_invoker and (anon_select or auth_select)),
    'exposed_materialized_view_count',(select count(*) from public_views where view_type='materialized_view' and (anon_select or auth_select)),
    'client_role_bypassrls_count',(select count(*) from client_roles where rolbypassrls or rolsuper),
    'public_schema_client_create',jsonb_build_object(
      'PUBLIC',exists(select 1 from schema_acl where grantee=0 and privilege_type='CREATE'),
      'anon',has_schema_privilege('anon','public','CREATE'),
      'authenticated',has_schema_privilege('authenticated','public','CREATE')
    ),
    'broad_default_acl_count',(select count(*) from default_acl_exposure),
    'extensions_in_public_count',(select count(*) from public_extensions),
    'foreign_tables_in_public_count',(select count(*) from public_foreign_tables),
    'sensitive_column_count',(select count(*) from sensitive_columns),
    'realtime_publication_count',(select count(*) from realtime_publications)
  ) as j
),
critical_metrics as (
  select
    (select count(*) from public_tables where not rls_enabled) +
    (select count(*) from public_functions where anon_execute and security_definer) +
    (select count(*) from public_functions where security_definer and configured_search_path is null) +
    (select count(*) from public_views where view_type='view' and not security_invoker and (anon_select or auth_select)) +
    (select count(*) from client_roles where rolbypassrls or rolsuper) +
    case when exists(select 1 from schema_acl where grantee=0 and privilege_type='CREATE')
      or has_schema_privilege('anon','public','CREATE')
      or has_schema_privilege('authenticated','public','CREATE') then 1 else 0 end
    as critical_structural_count
)
select jsonb_pretty(jsonb_build_object(
  'audit','PHASE5_SUPABASE_RLS_PRIVILEGE_AUDIT',
  'audit_mode','READ_ONLY',
  'audited_at',clock_timestamp(),
  'summary',(select j from summary),
  'preliminary_structural_status',case when (select critical_structural_count from critical_metrics)=0 then 'NO_STRUCTURAL_CRITICAL_FOUND' else 'CRITICAL_FINDINGS_REQUIRE_REVIEW' end,
  'critical_structural_count',(select critical_structural_count from critical_metrics),
  'rls_disabled_tables',coalesce((select jsonb_agg(jsonb_build_object('table',table_name,'owner',owner_name,'anon_select',anon_select,'anon_insert',anon_insert,'anon_update',anon_update,'anon_delete',anon_delete,'auth_select',auth_select,'auth_insert',auth_insert,'auth_update',auth_update,'auth_delete',auth_delete) order by table_name) from public_tables where not rls_enabled),'[]'::jsonb),
  'rls_enabled_without_policy',coalesce((select jsonb_agg(table_name order by table_name) from public_tables where rls_enabled and policy_count=0),'[]'::jsonb),
  'anon_accessible_tables',coalesce((select jsonb_agg(jsonb_build_object('table',table_name,'select',anon_select,'insert',anon_insert,'update',anon_update,'delete',anon_delete,'rls',rls_enabled,'policies',policy_count) order by table_name) from public_tables where anon_select or anon_insert or anon_update or anon_delete),'[]'::jsonb),
  'authenticated_direct_write_tables',coalesce((select jsonb_agg(jsonb_build_object('table',table_name,'insert',auth_insert,'update',auth_update,'delete',auth_delete,'rls',rls_enabled,'policies',policy_count) order by table_name) from public_tables where auth_insert or auth_update or auth_delete),'[]'::jsonb),
  'policies',coalesce((select jsonb_agg(jsonb_build_object('table',table_name,'policy',policy_name,'command',command,'permissive',permissive,'roles',roles,'using',using_expression,'with_check',check_expression,'unconditional_true',unconditional_true) order by table_name,policy_name) from policy_details),'[]'::jsonb),
  'unconditional_true_policies',coalesce((select jsonb_agg(jsonb_build_object('table',table_name,'policy',policy_name,'command',command,'roles',roles) order by table_name,policy_name) from policy_details where unconditional_true),'[]'::jsonb),
  'anon_executable_functions',coalesce((select jsonb_agg(jsonb_build_object('function',signature,'security_definer',security_definer,'returns_trigger',returns_trigger,'search_path',configured_search_path,'row_security_off',row_security_off,'public_execute',public_execute) order by signature) from public_functions where anon_execute),'[]'::jsonb),
  'public_execute_functions',coalesce((select jsonb_agg(jsonb_build_object('function',signature,'security_definer',security_definer,'returns_trigger',returns_trigger,'auth_execute',auth_execute,'anon_execute',anon_execute) order by signature) from public_functions where public_execute),'[]'::jsonb),
  'authenticated_security_definer_functions',coalesce((select jsonb_agg(jsonb_build_object('function',signature,'search_path',configured_search_path,'row_security_off',row_security_off,'returns_trigger',returns_trigger,'public_execute',public_execute) order by signature) from public_functions where auth_execute and security_definer),'[]'::jsonb),
  'security_definer_without_search_path',coalesce((select jsonb_agg(signature order by signature) from public_functions where security_definer and configured_search_path is null),'[]'::jsonb),
  'views',coalesce((select jsonb_agg(jsonb_build_object('view',view_name,'type',view_type,'security_invoker',security_invoker,'anon_select',anon_select,'auth_select',auth_select) order by view_name) from public_views),'[]'::jsonb),
  'client_roles',coalesce((select jsonb_agg(jsonb_build_object('role',rolname,'bypass_rls',rolbypassrls,'superuser',rolsuper) order by rolname) from client_roles),'[]'::jsonb),
  'default_acl_exposure',coalesce((select jsonb_agg(jsonb_build_object('owner',owner_name,'schema',schema_name,'object_type',object_type,'grantee',grantee,'privilege',privilege_type) order by owner_name,schema_name,object_type,grantee,privilege_type) from default_acl_exposure),'[]'::jsonb),
  'extensions_in_public',coalesce((select jsonb_agg(extension_name order by extension_name) from public_extensions),'[]'::jsonb),
  'foreign_tables_in_public',coalesce((select jsonb_agg(table_name order by table_name) from public_foreign_tables),'[]'::jsonb),
  'sensitive_columns',coalesce((select jsonb_agg(jsonb_build_object('table',table_name,'column',column_name,'anon_select',anon_select,'auth_select',auth_select) order by table_name,column_name) from sensitive_columns),'[]'::jsonb),
  'realtime_publications',coalesce((select jsonb_agg(jsonb_build_object('publication',pubname,'table',tablename) order by pubname,tablename) from realtime_publications),'[]'::jsonb),
  'notes',jsonb_build_array(
    'authenticated SECURITY DEFINER functions are not automatically vulnerabilities: each must be reviewed against its internal authorization checks.',
    'An RLS-enabled table with zero policies is deny-by-default; this is usually safe but may indicate a functionality/configuration issue.',
    'A publishable/anon project key in browser code is expected; service_role/secret keys must never be present in the frontend.',
    'Supplier/receiver global authenticated SELECT is a business privacy decision and will be reviewed separately after this inventory.'
  )
)) as phase5_security_audit;
