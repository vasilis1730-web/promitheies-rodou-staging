-- Αναγνωστικός τελικός έλεγχος για το promitheies-rodou-staging.
-- Δεν δημιουργεί, μεταβάλλει ή διαγράφει δεδομένα.

select
  public.app_schema_version() as schema_version,
  (select count(*) from public.municipal_units where is_active) as active_units,
  (select count(*) from public.procurement_groups
    where domain = 'procurement' and is_active) as procurement_groups,
  (select count(*) from public.procurement_groups
    where domain = 'service' and is_active) as service_groups,
  (select count(*) from public.materials m
    join public.procurement_groups g on g.id = m.group_id
    where g.domain = 'procurement' and m.is_active) as procurement_items,
  (select count(*) from public.materials m
    join public.procurement_groups g on g.id = m.group_id
    where g.domain = 'service' and m.is_active) as service_items,
  (select count(*) from public.materials m
    join public.procurement_groups g on g.id = m.group_id
    where g.domain = 'service' and m.is_active
      and nullif(btrim(m.standards), '') is null) as services_without_standards,
  (select count(*) from public.materials where is_active) as active_materials,
  (select count(*) from public.app_catalog_migrations
    where id = '202608050007_service_catalog') as service_catalog_migration,
  (select count(*) from public.app_rhodes_award_group_template()) as rhodes_template_units,
  (select count(distinct group_no)
    from public.app_rhodes_award_group_template()) as rhodes_template_groups,
  (select count(*) from auth.users) as auth_users,
  (select count(*) from public.locked_studies) as locked_studies,
  (select count(*) from public.mo_contracts) as contracts,
  (select count(*) from public.mo_orders) as material_orders,
  (select format_type(a.atttypid, a.atttypmod)
     from pg_attribute a
    where a.attrelid = 'public.unit_requests'::regclass
      and a.attname = 'id'
      and a.attnum > 0
      and not a.attisdropped) as request_id_type,
  (select format_type(a.atttypid, a.atttypmod)
     from pg_attribute a
    where a.attrelid = 'public.app_excel_import_tokens'::regclass
      and a.attname = 'used_request_id'
      and a.attnum > 0
      and not a.attisdropped) as excel_request_id_type,
  (select count(*)
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and not c.relrowsecurity) as public_tables_without_rls;
