-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — v36.6.1 ORDER ISSUE & PURGE AUDIT HOTFIX
-- Αρχείο: supabase/migrations/202608070001_fix_order_issue_and_purge_audit.sql
--
-- ΤΙ ΔΙΟΡΘΩΝΕΙ
--   1) public.mo_orders.issued_by — η στήλη χρησιμοποιείται από τη
--      save_order_atomic (INSERT και UPDATE) αλλά δεν δημιουργήθηκε ποτέ,
--      ούτε από το 00_FULL_INSTALL ούτε από καμία migration. Αποτέλεσμα:
--      αποτυχία ακόμη και σε απλή αποθήκευση πρόχειρου δελτίου με
--      «column "issued_by" of relation "mo_orders" does not exist».
--
--   2) public.mo_orders_status_check — το CHECK του installer επιτρέπει μόνο
--      ('draft','sent','received','cancelled'), ενώ η issue_material_order_atomic
--      θέτει status='issued' και ο app_order_guard επιτρέπει draft->issued.
--      Αποτέλεσμα: κάθε έκδοση δελτίου απορρίπτεται από τη βάση.
--
--   3) public.saved_versions_action_check — το CHECK του installer δέχεται μόνο
--      ('save','save_clean','export_excel','tender_document','lock','unlock'),
--      ενώ τα RPC γράφουν επιπλέον 'copy', 'import' και 'cancel_lock'.
--      Αποτέλεσμα: αποτυγχάνουν η αντιγραφή αιτήματος, η ασφαλής εισαγωγή
--      Excel και η ακύρωση κλειδωμένης μελέτης.
--
--   4) admin_purge_locked_study_atomic — η πλήρης διαγραφή έσβηνε και τις
--      εγγραφές του app_audit_log, χωρίς να καταγράφει την ίδια τη διαγραφή.
--      Η μελέτη εξαφανιζόταν χωρίς κανένα ίχνος. Πλέον οι εγγραφές ιστορικού
--      ΔΙΑΤΗΡΟΥΝΤΑΙ και γράφεται event 'study_purged' με πλήρη στοιχεία.
--
-- ΑΣΦΑΛΕΙΑ
--   Επαναλήψιμη. Δεν μεταβάλλει υπάρχοντα δελτία, μελέτες ή κατάλογο.
--   Εκτελείται ΜΟΝΟ σε βάση που έχει ήδη τη 202608060004.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- Προέλεγχος: η βάση πρέπει να βρίσκεται στη v36.6.0
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.mo_orders') is null then
    raise exception 'Δεν βρέθηκε ο πίνακας public.mo_orders. Εκτελέστε πρώτα το 00_FULL_INSTALL.';
  end if;
  if to_regclass('public.study_templates') is null then
    raise exception 'Δεν βρέθηκε ο πίνακας public.study_templates. Εκτελέστε πρώτα τη 202608060004.';
  end if;
  if to_regprocedure('public.admin_purge_locked_study_atomic(text,text)') is null then
    raise exception 'Δεν βρέθηκε η admin_purge_locked_study_atomic. Εκτελέστε πρώτα τη 202608060004.';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Στήλη issued_by
-- ---------------------------------------------------------------------------
alter table public.mo_orders
  add column if not exists issued_by uuid null references auth.users(id) on delete set null;

comment on column public.mo_orders.issued_by is
  'Χρήστης που εξέδωσε το δελτίο. Συμπληρώνεται από τη save_order_atomic κατά την έκδοση και μηδενίζεται σε επαναφορά σε πρόχειρο.';

create index if not exists idx_mo_orders_issued_by
  on public.mo_orders(issued_by)
  where issued_by is not null;

-- ---------------------------------------------------------------------------
-- 2. Διεύρυνση του CHECK ώστε να περιλαμβάνει την κατάσταση 'issued'
--    Πρώτα ελέγχεται ότι δεν υπάρχει ήδη μη έγκυρη τιμή στα δεδομένα.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from public.mo_orders o
  where o.status not in ('draft', 'issued', 'sent', 'received', 'cancelled');

  if v_bad > 0 then
    raise exception 'Βρέθηκαν % δελτία με μη αναγνωρίσιμη κατάσταση. Διορθώστε τα πριν από τη migration.', v_bad;
  end if;
end $$;

alter table public.mo_orders
  drop constraint if exists mo_orders_status_check;

alter table public.mo_orders
  add constraint mo_orders_status_check
  check (status in ('draft', 'issued', 'sent', 'received', 'cancelled'));

comment on constraint mo_orders_status_check on public.mo_orders is
  'Επιτρεπτές καταστάσεις δελτίου. Η ενδιάμεση «issued» δεσμεύει υπόλοιπο μελέτης και καθιστά το δελτίο αμετάβλητο.';

-- ---------------------------------------------------------------------------
-- 3. saved_versions.action — το CHECK του installer δεν περιλάμβανε τις
--    τιμές που γράφουν στην πραγματικότητα τα RPC:
--      'copy'        <- copy_unit_request_atomic
--      'import'      <- secure_import_catalog_request_atomic
--      'cancel_lock' <- cancel_locked_study_atomic
--    Χωρίς τη διόρθωση, η αντιγραφή αιτήματος, η ασφαλής εισαγωγή Excel και
--    η ακύρωση κλειδωμένης μελέτης αποτυγχάνουν με
--    «violates check constraint "saved_versions_action_check"».
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from public.saved_versions v
  where v.action not in (
    'save', 'save_clean', 'export_excel', 'tender_document',
    'lock', 'unlock', 'copy', 'import', 'cancel_lock'
  );
  if v_bad > 0 then
    raise exception 'Βρέθηκαν % αποθηκευμένες εκδόσεις με μη αναγνωρίσιμη ενέργεια.', v_bad;
  end if;
end $$;

alter table public.saved_versions
  drop constraint if exists saved_versions_action_check;

alter table public.saved_versions
  add constraint saved_versions_action_check
  check (action in (
    'save', 'save_clean', 'export_excel', 'tender_document',
    'lock', 'unlock', 'copy', 'import', 'cancel_lock'
  ));

comment on constraint saved_versions_action_check on public.saved_versions is
  'Επιτρεπτές ενέργειες αποθηκευμένης έκδοσης, όπως τις γράφουν τα ατομικά RPC της v36.';

-- ---------------------------------------------------------------------------
-- 4. Πλήρης διαγραφή μελέτης με διατήρηση αμετάβλητου ιστορικού
-- ---------------------------------------------------------------------------
create or replace function public.admin_purge_locked_study_atomic(
  p_study_id text,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_study public.locked_studies%rowtype;
  v_order_items integer := 0;
  v_orders integer := 0;
  v_contract_items integer := 0;
  v_contracts integer := 0;
  v_versions integer := 0;
  v_exports integer := 0;
  v_templates_detached integer := 0;
  v_audit_kept integer := 0;
  v_order_numbers text[];
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο administrator μπορεί να εκτελέσει πλήρη διαγραφή κλειδωμένης μελέτης.';
  end if;
  if upper(btrim(coalesce(p_confirmation, ''))) <> 'ΔΙΑΓΡΑΦΗ' then
    raise exception 'Η πλήρης διαγραφή απαιτεί την επιβεβαίωση «ΔΙΑΓΡΑΦΗ».';
  end if;

  select * into v_study
  from public.locked_studies s
  where s.id::text = p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;

  -- Οι αριθμοί των δελτίων καταγράφονται ΠΡΙΝ διαγραφούν, ώστε να παραμείνει
  -- ελέγξιμο ποια εκδοθέντα παραστατικά αφαιρέθηκαν.
  select coalesce(array_agg(o.order_no order by o.order_no), '{}')
  into v_order_numbers
  from public.mo_orders o
  where o.study_id = v_study.id and o.order_no is not null;

  select count(*) into v_audit_kept
  from public.app_audit_log a
  where a.entity_id = v_study.id::text;

  perform set_config('app.admin_purge_mode', 'on', true);

  -- Το πρότυπο είναι αυτοτελές και δεν χάνεται μαζί με την πηγή του.
  update public.study_templates t
  set source_study_id = null,
      updated_at = now(),
      updated_by = auth.uid()
  where t.source_study_id = v_study.id;
  get diagnostics v_templates_detached = row_count;

  -- Στοχευμένη διαγραφή: μόνο το στιγμιότυπο κλειδώματος της συγκεκριμένης
  -- μελέτης, όχι κάθε έκδοση που τυχαίνει να αναφέρει το αναγνωριστικό.
  delete from public.saved_versions v
  where v.action = 'lock'
    and v.snapshot ->> 'locked_study_id' = v_study.id::text;
  get diagnostics v_versions = row_count;

  delete from public.export_jobs e
  where position(v_study.id::text in coalesce(e.payload::text, '')) > 0;
  get diagnostics v_exports = row_count;

  delete from public.mo_order_items oi
  where oi.order_id in (
    select o.id from public.mo_orders o where o.study_id = v_study.id
  );
  get diagnostics v_order_items = row_count;

  delete from public.mo_orders o where o.study_id = v_study.id;
  get diagnostics v_orders = row_count;

  delete from public.mo_contract_items ci
  where ci.contract_id in (
    select c.id from public.mo_contracts c where c.source_study_id = v_study.id
  );
  get diagnostics v_contract_items = row_count;

  delete from public.mo_contracts c where c.source_study_id = v_study.id;
  get diagnostics v_contracts = row_count;

  delete from public.locked_studies s where s.id = v_study.id;
  if not found then raise exception 'Η κλειδωμένη μελέτη δεν διαγράφηκε.'; end if;

  perform set_config('app.admin_purge_mode', 'off', true);

  -- Το app_audit_log ΔΕΝ καθαρίζεται. Η ίδια η διαγραφή καταγράφεται με
  -- πλήρες στιγμιότυπο, ώστε καμία μελέτη να μην εξαφανίζεται χωρίς ίχνος.
  perform public.app_write_audit(
    'study_purged', 'locked_studies', v_study.id::text,
    v_study.municipal_unit_id::bigint,
    'Πλήρης διαγραφή κλειδωμένης μελέτης από administrator.',
    to_jsonb(v_study),
    null,
    jsonb_build_object(
      'study_seq', v_study.seq,
      'group_id', v_study.group_id,
      'request_year', v_study.request_year,
      'net_total', v_study.net_total,
      'item_count', v_study.item_count,
      'deleted_order_items', v_order_items,
      'deleted_orders', v_orders,
      'deleted_order_numbers', to_jsonb(v_order_numbers),
      'deleted_contract_items', v_contract_items,
      'deleted_contracts', v_contracts,
      'deleted_saved_versions', v_versions,
      'deleted_export_jobs', v_exports,
      'retained_audit_entries', v_audit_kept,
      'detached_templates', v_templates_detached
    )
  );

  return jsonb_build_object(
    'study_id', v_study.id::text,
    'study_seq', v_study.seq,
    'municipal_unit_id', v_study.municipal_unit_id,
    'group_id', v_study.group_id,
    'request_year', v_study.request_year,
    'deleted', true,
    'deleted_order_items', v_order_items,
    'deleted_orders', v_orders,
    'deleted_contract_items', v_contract_items,
    'deleted_contracts', v_contracts,
    'deleted_saved_versions', v_versions,
    'deleted_export_jobs', v_exports,
    'retained_audit_entries', v_audit_kept,
    'detached_templates', v_templates_detached
  );
end;
$$;

revoke all on function public.admin_purge_locked_study_atomic(text,text)
  from public, anon, authenticated;
grant execute on function public.admin_purge_locked_study_atomic(text,text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Έκδοση σχήματος
-- ---------------------------------------------------------------------------
create or replace function public.app_schema_version()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select '36.6.1'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

commit;
