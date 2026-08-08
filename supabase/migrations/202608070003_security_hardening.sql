-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΘΩΡΑΚΙΣΗ ΠΡΙΝ ΑΠΟ ΔΗΜΟΣΙΟ ΑΠΟΘΕΤΗΡΙΟ
-- Αρχείο: supabase/migrations/202608070003_security_hardening.sql
--
-- Διορθώνει τα ευρήματα του Supabase security linter:
--   1 ERROR  — όψη με δικαιώματα δημιουργού που παρέκαμπτε το RLS
--   2 WARN   — συναρτήσεις trigger εκτεθειμένες στο REST API
--  11 WARN   — συναρτήσεις με μεταβλητό search_path
--
-- Επαναλήψιμη. Δεν μεταβάλλει δεδομένα.
-- ΣΗΜΑΝΤΙΚΟ: η rls_auto_enable() είναι προαιρετική helper function του
-- περιβάλλοντος Supabase και δεν θεωρείται πλέον υποχρεωτικό repo object.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Η όψη κάλυψης προδιαγραφών έτρεχε με δικαιώματα δημιουργού και
--    παρέκαμπτε το RLS του καλούντος.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.v_specs_coverage') is not null then
    execute 'alter view public.v_specs_coverage set (security_invoker = true)';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Συναρτήσεις trigger και εσωτερικά βοηθητικά δεν πρέπει να είναι
--    καλέσιμα μέσω /rest/v1/rpc/.
-- ---------------------------------------------------------------------------
revoke all on function public.app_generic_audit_trigger() from public, anon, authenticated;
revoke all on function public.set_updated_at()            from public, anon, authenticated;

-- Η rls_auto_enable() δεν δημιουργείται από το installer της εφαρμογής.
-- Αν υπάρχει στο συγκεκριμένο Supabase project, θωρακίζεται. Αν δεν υπάρχει,
-- η migration συνεχίζει κανονικά αντί να κάνει rollback ολόκληρο το hardening.
do $$
begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke all on function public.rls_auto_enable() from public, anon, authenticated;
    alter function public.rls_auto_enable() set search_path = public, pg_temp;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Καρφωμένο search_path, ώστε να μην είναι δυνατή παραπλάνηση μέσω
--    ομώνυμων αντικειμένων σε άλλο schema.
-- ---------------------------------------------------------------------------
alter function public.set_updated_at()                              set search_path = public, pg_temp;
alter function public.app_generic_audit_trigger()                   set search_path = public, pg_temp;
alter function public.app_greek_key(text)                           set search_path = public, pg_temp;
alter function public.app_unit_key(text)                            set search_path = public, pg_temp;
alter function public.app_unit_default_scale(text)                  set search_path = public, pg_temp;
alter function public.app_quantity_matches_scale(numeric, smallint) set search_path = public, pg_temp;
alter function public.app_rhodes_award_group_no(bigint)             set search_path = public, pg_temp;
alter function public.app_rhodes_award_group_no(text, text)         set search_path = public, pg_temp;
alter function public.app_rhodes_award_group_name(integer)          set search_path = public, pg_temp;
alter function public.app_rhodes_municipal_unit_code(text, text)    set search_path = public, pg_temp;

commit;

-- ============================================================================
-- ΣΗΜΕΙΩΣΗ
--   Οι υπόλοιπες προειδοποιήσεις του linter είναι σχεδιαστικές και ΔΕΝ
--   διορθώνονται:
--
--   • Τα *_atomic RPC είναι SECURITY DEFINER και καλέσιμα από συνδεδεμένους
--     χρήστες κατά σχεδιασμό. Το καθένα εκτελεί δικό του έλεγχο δικαιωμάτων
--     (app_is_admin / app_can_write_unit κ.λπ.). Αυτή είναι η αρχιτεκτονική:
--     ο ρόλος authenticated δεν έχει απευθείας INSERT/UPDATE/DELETE στους
--     πίνακες, μόνο SELECT.
--
--   • Οι πίνακες app_catalog_migrations, app_excel_import_tokens και
--     mo_order_number_counters έχουν RLS χωρίς permissive policy. Αυτό σημαίνει
--     «απαγόρευση σε όλους», που είναι το επιθυμητό: προσπελαύνονται
--     αποκλειστικά μέσα από SECURITY DEFINER συναρτήσεις.
--
--   • Η rls_auto_enable(), όταν υπάρχει, είναι περιβαλλοντικό hardening και
--     όχι προαπαιτούμενο της εφαρμογής.
-- ============================================================================
