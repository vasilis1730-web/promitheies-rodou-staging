-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — 105_VERIFY_ORDER_ISSUE_HOTFIX.sql
--
-- ΑΥΣΤΗΡΑ ΑΝΑΓΝΩΣΤΙΚΟΣ ΕΛΕΓΧΟΣ. Δεν μεταβάλλει τίποτε.
-- Εκτελείται ΜΕΤΑ τη migration 202608070001.
--
-- Αναμενόμενο αποτέλεσμα: κάθε γραμμή του τελικού πίνακα «✅ ΟΚ».
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Συνολικός πίνακας ελέγχων
-- ---------------------------------------------------------------------------
with checks as (

  select 1 as α_α,
    'Έκδοση σχήματος βάσης' as ελεγχος,
    public.app_schema_version() as ευρεθεν,
    '36.6.1' as αναμενομενο

  union all select 2,
    'Στήλη mo_orders.issued_by',
    coalesce((
      select 'υπάρχει (' || data_type || ')'
      from information_schema.columns
      where table_schema = 'public' and table_name = 'mo_orders'
        and column_name = 'issued_by'
    ), 'ΛΕΙΠΕΙ'),
    'υπάρχει (uuid)'

  union all select 3,
    'Κατάσταση δελτίου «issued» επιτρεπτή',
    case when (
      select pg_get_constraintdef(oid) from pg_constraint
      where conrelid = 'public.mo_orders'::regclass and conname = 'mo_orders_status_check'
    ) like '%issued%' then 'ναι' else 'ΟΧΙ' end,
    'ναι'

  union all select 4,
    'saved_versions.action δέχεται copy/import/cancel_lock',
    case when (
      select pg_get_constraintdef(oid) from pg_constraint
      where conrelid = 'public.saved_versions'::regclass
        and conname = 'saved_versions_action_check'
    ) like '%cancel_lock%' then 'ναι' else 'ΟΧΙ' end,
    'ναι'

  union all select 5,
    'RPC πλήρους διαγραφής',
    case when to_regprocedure('public.admin_purge_locked_study_atomic(text,text)') is null
      then 'ΛΕΙΠΕΙ' else 'υπάρχει' end,
    'υπάρχει'

  union all select 6,
    'Η πλήρης διαγραφή ΔΕΝ σβήνει πλέον το app_audit_log',
    case when (
      select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_purge_locked_study_atomic'
    ) like '%delete from public.app_audit_log%' then 'ΣΒΗΝΕΙ' else 'διατηρεί' end,
    'διατηρεί'

  union all select 7,
    'Η πλήρης διαγραφή καταγράφεται ως study_purged',
    case when (
      select prosrc from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'admin_purge_locked_study_atomic'
    ) like '%study_purged%' then 'ναι' else 'ΟΧΙ' end,
    'ναι'

  union all select 8,
    'Πίνακας προτύπων μελέτης',
    case when to_regclass('public.study_templates') is null
      then 'ΛΕΙΠΕΙ' else 'υπάρχει' end,
    'υπάρχει'

  union all select 9,
    'Δικαιώματα authenticated στα mo_orders (μόνο ανάγνωση)',
    (select string_agg(privilege_type, ',' order by privilege_type)
     from information_schema.role_table_grants
     where grantee = 'authenticated' and table_schema = 'public' and table_name = 'mo_orders'),
    'SELECT'

  union all select 10,
    'Δημοτικές Ενότητες (10 + κεντρική)',
    (select count(*)::text from public.municipal_units),
    '11'

  union all select 11,
    'Δελτία με μη επιτρεπτή κατάσταση',
    (select count(*)::text from public.mo_orders
     where status not in ('draft','issued','sent','received','cancelled')),
    '0'

  union all select 12,
    'Αποθηκευμένες εκδόσεις με μη επιτρεπτή ενέργεια',
    (select count(*)::text from public.saved_versions
     where action not in ('save','save_clean','export_excel','tender_document',
                          'lock','unlock','copy','import','cancel_lock')),
    '0'
)
select
  α_α                                   as "Α/Α",
  ελεγχος                               as "Έλεγχος",
  coalesce(ευρεθεν, '(κενό)')           as "Ευρέθηκε",
  αναμενομενο                           as "Αναμενόμενο",
  case when ευρεθεν is not distinct from αναμενομενο
    then '✅ ΟΚ' else '❌ ΑΠΟΤΥΧΙΑ' end as "Αποτέλεσμα"
from checks
order by α_α;

-- ---------------------------------------------------------------------------
-- 2. Ενεργή κατανομή ομάδων Δ.Ε. του τρέχοντος έτους
-- ---------------------------------------------------------------------------
select
  g.group_no                                          as "Ομάδα",
  g.name                                              as "Ονομασία",
  count(m.municipal_unit_id)                          as "Πλήθος Δ.Ε.",
  string_agg(u.short_name, ', ' order by u.short_name) as "Δημοτικές Ενότητες",
  to_char(c.direct_award_cap, 'FM999G999D00') || ' €'  as "Κοινό όριο"
from public.award_group_configurations c
join public.award_groups g on g.configuration_id = c.id
left join public.award_group_memberships m
  on m.configuration_id = c.id and m.award_group_id = g.id
left join public.municipal_units u on u.id = m.municipal_unit_id
where c.is_active
group by g.group_no, g.name, c.direct_award_cap
order by g.group_no;

-- ---------------------------------------------------------------------------
-- 3. Σύνοψη κίνησης ανά κατάσταση δελτίου
-- ---------------------------------------------------------------------------
select
  o.status                                              as "Κατάσταση",
  count(*)                                              as "Πλήθος",
  to_char(coalesce(sum(o.subtotal), 0), 'FM999G999D00') as "Καθαρή αξία (€)"
from public.mo_orders o
group by o.status
order by o.status;
