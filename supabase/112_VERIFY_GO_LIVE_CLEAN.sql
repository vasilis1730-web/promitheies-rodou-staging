-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — VERIFY OFFICIAL GO-LIVE CLEAN STATE v36.6.5
-- Read-only. Δεν μεταβάλλει δεδομένα.
-- ============================================================================

with
operational_counts as (
  select jsonb_build_object(
    'unit_requests',            (select count(*) from public.unit_requests),
    'request_lines',            (select count(*) from public.request_lines),
    'saved_versions',           (select count(*) from public.saved_versions),
    'export_jobs',              (select count(*) from public.export_jobs),
    'locked_studies',           (select count(*) from public.locked_studies),
    'study_templates',          (select count(*) from public.study_templates),
    'mo_suppliers',             (select count(*) from public.mo_suppliers),
    'mo_receivers',             (select count(*) from public.mo_receivers),
    'mo_projects',              (select count(*) from public.mo_projects),
    'mo_contracts',             (select count(*) from public.mo_contracts),
    'mo_contract_items',        (select count(*) from public.mo_contract_items),
    'mo_orders',                (select count(*) from public.mo_orders),
    'mo_order_items',           (select count(*) from public.mo_order_items),
    'mo_counters',              (select count(*) from public.mo_counters),
    'app_excel_import_tokens',  (select count(*) from public.app_excel_import_tokens),
    'tender_overrides',         (select count(*) from public.tender_overrides),
    'app_audit_log',            (select count(*) from public.app_audit_log)
  ) j
),
masters as (
  select jsonb_build_object(
    'active_materials', (select count(*) from public.materials where is_active),
    'procurement_items', (
      select count(*) from public.materials m
      join public.procurement_groups g on g.id=m.group_id
      where m.is_active and g.domain='procurement'
    ),
    'service_items', (
      select count(*) from public.materials m
      join public.procurement_groups g on g.id=m.group_id
      where m.is_active and g.domain='service'
    ),
    'active_profiles', (select count(*) from public.profiles where is_active),
    'award_groups_2026', (
      select count(*) from public.award_groups g
      join public.award_group_configurations c on c.id=g.configuration_id
      where c.budget_year=2026
    ),
    'award_memberships_2026', (
      select count(*) from public.award_group_memberships m
      join public.award_group_configurations c on c.id=m.configuration_id
      where c.budget_year=2026
    )
  ) j
),
decision as (
  select jsonb_build_object(
    'budget_year',c.budget_year,
    'decision_number',c.decision_number,
    'decision_date',c.decision_date,
    'decision_ada',c.decision_ada,
    'direct_award_cap',c.direct_award_cap,
    'is_active',c.is_active
  ) j
  from public.award_group_configurations c
  where c.budget_year=2026
),
trigger_checks as (
  select jsonb_build_object(
    'locked_studies_immutable_enabled', exists(
      select 1 from pg_trigger where tgname='trg_locked_studies_immutable' and not tgisinternal and tgenabled<>'D'
    ),
    'orders_immutable_enabled', exists(
      select 1 from pg_trigger where tgname='trg_mo_orders_immutable' and not tgisinternal and tgenabled<>'D'
    ),
    'contract_items_immutable_enabled', exists(
      select 1 from pg_trigger where tgname='trg_mo_contract_items_immutable' and not tgisinternal and tgenabled<>'D'
    ),
    'contract_pricing_guard_enabled', exists(
      select 1 from pg_trigger where tgname='trg_mo_contracts_pricing_header_guard' and not tgisinternal and tgenabled<>'D'
    ),
    'order_financial_guard_enabled', exists(
      select 1 from pg_trigger where tgname='trg_mo_orders_contract_financial_guard' and not tgisinternal and tgenabled<>'D'
    )
  ) j
),
checks as (
  select jsonb_build_object(
    'schema_is_36_6_5', public.app_schema_version()='36.6.5',
    'operational_tables_all_zero',
      (select bool_and((value)::bigint=0) from operational_counts, jsonb_each_text(operational_counts.j)),
    'active_materials_present', (select (masters.j->>'active_materials')::bigint>0 from masters),
    'active_profiles_present', (select (masters.j->>'active_profiles')::bigint>0 from masters),
    'four_award_groups', (select (masters.j->>'award_groups_2026')::int=4 from masters),
    'ten_award_memberships', (select (masters.j->>'award_memberships_2026')::int=10 from masters),
    'decision_number_ok', coalesce((select decision.j->>'decision_number'='195/2026' from decision),false),
    'decision_date_ok', coalesce((select decision.j->>'decision_date'='2026-07-21' from decision),false),
    'decision_ada_ok', coalesce((select decision.j->>'decision_ada'='9ΒΜΣΩ1Ρ-ΣΝ3' from decision),false),
    'direct_award_cap_ok', coalesce((select (decision.j->>'direct_award_cap')::numeric=30000 from decision),false),
    'decision_active', coalesce((select (decision.j->>'is_active')::boolean from decision),false),
    'immutable_guards_enabled',
      (select bool_and((value)::boolean) from trigger_checks, jsonb_each_text(trigger_checks.j))
  ) j
)
select jsonb_pretty(jsonb_build_object(
  'verified_at',clock_timestamp(),
  'schema_version',public.app_schema_version(),
  'go_live_ready',(
    select bool_and((value)::boolean)
    from checks, jsonb_each_text(checks.j)
  ),
  'checks',(select j from checks),
  'operational_counts',(select j from operational_counts),
  'master_data',(select j from masters),
  'decision_2026',coalesce((select j from decision),'{}'::jsonb),
  'guards',(select j from trigger_checks)
)) as go_live_verification;
