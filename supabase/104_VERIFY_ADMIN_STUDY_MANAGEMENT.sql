-- v36.6.0 — Αναγνωστικός έλεγχος διαχείρισης μελετών.
-- Δεν δημιουργεί, δεν ενημερώνει και δεν διαγράφει δεδομένα.

select
  public.app_schema_version() as schema_version,
  case when to_regclass('public.study_templates') is not null then 1 else 0 end as study_templates_table,
  (
    select count(*)
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname in (
        'save_locked_study_as_template_atomic',
        'load_study_template_atomic',
        'delete_study_template_atomic',
        'admin_purge_locked_study_atomic'
      )
  ) as management_rpcs,
  (
    select count(*)
    from pg_policies
    where schemaname = 'public'
      and tablename = 'study_templates'
      and policyname = 'study_templates_select_authenticated'
  ) as template_select_policies,
  (
    select count(*)
    from information_schema.role_routine_grants
    where routine_schema = 'public'
      and grantee = 'authenticated'
      and privilege_type = 'EXECUTE'
      and routine_name in (
        'save_locked_study_as_template_atomic',
        'load_study_template_atomic',
        'delete_study_template_atomic',
        'admin_purge_locked_study_atomic'
      )
  ) as authenticated_execute_grants,
  (select count(*) from public.study_templates where is_active) as active_templates,
  (select count(*) from public.locked_studies) as locked_studies,
  (select count(*) from public.mo_contracts where source_study_id is not null) as linked_contracts,
  (select count(*) from public.mo_orders where study_id is not null) as linked_orders;
