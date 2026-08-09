-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ONE-TIME GO-LIVE RESET v36.6.5
--
-- ΣΚΟΠΟΣ
--   Η staging εγκατάσταση χρησιμοποιήθηκε αποκλειστικά για δοκιμές πριν από
--   την επίσημη έναρξη. Το παρόν αρχείο καθαρίζει ΟΛΑ τα επιχειρησιακά/
--   δοκιμαστικά δεδομένα και αφήνει ανέπαφα τα master δεδομένα της εφαρμογής.
--
-- ΔΙΑΤΗΡΟΥΝΤΑΙ
--   * municipal_units
--   * procurement_groups
--   * materials / material_aliases / price_observations
--   * profiles / user_app_permissions / auth.users
--   * award_group_configurations / award_groups / award_group_memberships
--   * όλες οι συναρτήσεις, policies, triggers και migrations
--
-- ΔΙΑΓΡΑΦΟΝΤΑΙ
--   * unit_requests / request_lines / saved_versions / export_jobs
--   * locked_studies / study_templates
--   * mo_contracts / mo_contract_items / mo_orders / mo_order_items
--   * mo_suppliers / mo_receivers / mo_projects / mo_counters
--   * app_excel_import_tokens / tender_overrides / app_audit_log
--
-- ΠΑΡΑΜΕΤΡΟΠΟΙΗΣΗ ΑΠΟΦΑΣΗΣ 2026
--   Απόφαση Δ.Σ.: 195/2026
--   Ημερομηνία:   21/07/2026
--   ΑΔΑ:          9ΒΜΣΩ1Ρ-ΣΝ3
--
-- ΠΡΟΣΟΧΗ
--   Εκτελείται ΜΙΑ ΦΟΡΑ, μετά τις migrations v36.6.5 και πριν από την
--   επίσημη καταχώριση πραγματικών μελετών. Είναι σκόπιμα destructive.
-- ============================================================================

begin;

select pg_advisory_xact_lock(hashtext('promitheies_rodou_v36_6_5_go_live_reset'));

-- ---------------------------------------------------------------------------
-- 1. Αυστηρός προέλεγχος έκδοσης και αναγκαίων αντικειμένων
-- ---------------------------------------------------------------------------
do $$
declare
  v_version text;
  v_missing text[] := array[]::text[];
  v_name text;
begin
  if to_regprocedure('public.app_schema_version()') is null then
    raise exception 'Λείπει η public.app_schema_version(). Εφαρμόστε πρώτα τις migrations v36.6.5.';
  end if;

  select public.app_schema_version() into v_version;
  if v_version <> '36.6.5' then
    raise exception 'Το GO-LIVE RESET απαιτεί schema 36.6.5. Βρέθηκε: %', coalesce(v_version,'NULL');
  end if;

  foreach v_name in array array[
    'unit_requests','request_lines','saved_versions','export_jobs',
    'locked_studies','study_templates','tender_overrides',
    'mo_suppliers','mo_receivers','mo_projects','mo_contracts','mo_contract_items',
    'mo_orders','mo_order_items','mo_counters','app_excel_import_tokens','app_audit_log',
    'award_group_configurations','award_groups','award_group_memberships'
  ] loop
    if to_regclass('public.' || v_name) is null then
      v_missing := array_append(v_missing,v_name);
    end if;
  end loop;

  if cardinality(v_missing) > 0 then
    raise exception 'Λείπουν απαιτούμενοι πίνακες: %', array_to_string(v_missing,', ');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2. Έλεγχος ότι η canonical δομή των ομάδων 2026 υπάρχει πριν το reset
-- ---------------------------------------------------------------------------
do $$
declare
  v_configuration_id bigint;
  v_groups integer;
  v_members integer;
  v_bad_units integer;
begin
  select c.id into v_configuration_id
  from public.award_group_configurations c
  where c.budget_year=2026;

  if v_configuration_id is null then
    raise exception 'Δεν υπάρχει παραμετροποίηση ομάδων Δημοτικών Ενοτήτων για το 2026.';
  end if;

  select count(*) into v_groups
  from public.award_groups g
  where g.configuration_id=v_configuration_id;

  select count(*) into v_members
  from public.award_group_memberships m
  where m.configuration_id=v_configuration_id;

  select count(*) into v_bad_units
  from public.municipal_units u
  where u.id<>11
    and not exists (
      select 1 from public.award_group_memberships m
      where m.configuration_id=v_configuration_id
        and m.municipal_unit_id=u.id
    );

  if v_groups<>4 or v_members<>10 or v_bad_units<>0 then
    raise exception 'Η δομή ομάδων 2026 δεν είναι canonical: groups=%, memberships=%, missing_units=%',
      v_groups,v_members,v_bad_units;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Οριστικά metadata Απόφασης Δημοτικού Συμβουλίου
-- ---------------------------------------------------------------------------
do $decision$
begin
  update public.award_group_configurations
  set decision_number='195/2026',
      decision_date=date '2026-07-21',
      decision_ada='9ΒΜΣΩ1Ρ-ΣΝ3',
      direct_award_cap=30000.00,
      is_active=true,
      updated_at=now()
  where budget_year=2026;

  if not found then
    raise exception 'Δεν ενημερώθηκε η παραμετροποίηση ομάδων για το 2026.';
  end if;
end;
$decision$;

-- ---------------------------------------------------------------------------
-- 4. Πλήρης καθαρισμός ΟΛΩΝ των δοκιμαστικών επιχειρησιακών δεδομένων.
--
-- TRUNCATE αντί DELETE:
--   * δεν παρακάμπτει μόνιμα τους immutable guards,
--   * δεν απαιτεί προσωρινή απενεργοποίηση triggers,
--   * είναι atomic μέσα στο transaction,
--   * μηδενίζει identity counters μόνο στους παρακάτω test/operational πίνακες.
--
-- Δεν χρησιμοποιείται CASCADE. Αν στο μέλλον προστεθεί νέος εξωτερικός FK
-- προς κάποιον από αυτούς τους πίνακες, το script θα ΑΠΟΤΥΧΕΙ ασφαλώς αντί
-- να διαγράψει απρόβλεπτα δεδομένα.
-- ---------------------------------------------------------------------------
truncate table
  public.mo_order_items,
  public.mo_orders,
  public.mo_contract_items,
  public.mo_contracts,
  public.study_templates,
  public.locked_studies,
  public.saved_versions,
  public.export_jobs,
  public.request_lines,
  public.unit_requests,
  public.tender_overrides,
  public.mo_projects,
  public.mo_receivers,
  public.mo_suppliers,
  public.mo_counters,
  public.app_excel_import_tokens,
  public.app_audit_log
restart identity;

-- ---------------------------------------------------------------------------
-- 5. Τελικός hard gate: η βάση πρέπει να είναι πραγματικά καθαρή
-- ---------------------------------------------------------------------------
do $$
declare
  v_nonzero text[] := array[]::text[];
  v_count bigint;
  v_materials bigint;
  v_users bigint;
  v_groups bigint;
  v_members bigint;
  v_decision record;
begin
  select count(*) into v_count from public.unit_requests;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'unit_requests='||v_count); end if;
  select count(*) into v_count from public.request_lines;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'request_lines='||v_count); end if;
  select count(*) into v_count from public.saved_versions;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'saved_versions='||v_count); end if;
  select count(*) into v_count from public.export_jobs;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'export_jobs='||v_count); end if;
  select count(*) into v_count from public.locked_studies;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'locked_studies='||v_count); end if;
  select count(*) into v_count from public.study_templates;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'study_templates='||v_count); end if;
  select count(*) into v_count from public.mo_contracts;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_contracts='||v_count); end if;
  select count(*) into v_count from public.mo_contract_items;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_contract_items='||v_count); end if;
  select count(*) into v_count from public.mo_orders;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_orders='||v_count); end if;
  select count(*) into v_count from public.mo_order_items;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_order_items='||v_count); end if;
  select count(*) into v_count from public.mo_suppliers;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_suppliers='||v_count); end if;
  select count(*) into v_count from public.mo_receivers;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_receivers='||v_count); end if;
  select count(*) into v_count from public.mo_projects;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_projects='||v_count); end if;
  select count(*) into v_count from public.mo_counters;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'mo_counters='||v_count); end if;
  select count(*) into v_count from public.app_excel_import_tokens;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'app_excel_import_tokens='||v_count); end if;
  select count(*) into v_count from public.tender_overrides;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'tender_overrides='||v_count); end if;
  select count(*) into v_count from public.app_audit_log;
  if v_count<>0 then v_nonzero:=array_append(v_nonzero,'app_audit_log='||v_count); end if;

  if cardinality(v_nonzero)>0 then
    raise exception 'Το GO-LIVE RESET δεν μηδένισε όλους τους operational πίνακες: %',array_to_string(v_nonzero,', ');
  end if;

  -- Master-data safety checks: οι κατάλογοι και η πρόσβαση πρέπει να έχουν μείνει.
  select count(*) into v_materials from public.materials where is_active is true;
  select count(*) into v_users from public.profiles where is_active is true;
  select count(*) into v_groups
  from public.award_groups g join public.award_group_configurations c on c.id=g.configuration_id
  where c.budget_year=2026;
  select count(*) into v_members
  from public.award_group_memberships m join public.award_group_configurations c on c.id=m.configuration_id
  where c.budget_year=2026;

  if v_materials<=0 or v_users<=0 or v_groups<>4 or v_members<>10 then
    raise exception 'Master-data safety gate failed: active_materials=%, active_users=%, groups=%, memberships=%',
      v_materials,v_users,v_groups,v_members;
  end if;

  select decision_number,decision_date,decision_ada,direct_award_cap,is_active
  into v_decision
  from public.award_group_configurations
  where budget_year=2026;

  if v_decision.decision_number<>'195/2026'
     or v_decision.decision_date<>date '2026-07-21'
     or v_decision.decision_ada<>'9ΒΜΣΩ1Ρ-ΣΝ3'
     or v_decision.direct_award_cap<>30000.00
     or v_decision.is_active is not true then
    raise exception 'Τα metadata της Απόφασης 195/2026 δεν αποθηκεύτηκαν ακριβώς.';
  end if;
end;
$$;

commit;

-- Αναμενόμενο αποτέλεσμα μετά το COMMIT:
--   operational/test records = 0
--   schema_version = 36.6.5
--   4 award groups / 10 memberships preserved
--   Απόφαση = 195/2026, 21/07/2026, ΑΔΑ 9ΒΜΣΩ1Ρ-ΣΝ3
--   users + catalogs preserved
