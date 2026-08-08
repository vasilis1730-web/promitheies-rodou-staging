-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — v36.6.2 ΜΕΤΑΦΟΡΑ ΤΕΧΝΙΚΩΝ ΠΡΟΔΙΑΓΡΑΦΩΝ ΠΡΟΜΗΘΕΙΩΝ
-- Αρχείο: supabase/migrations/202608070002_technical_specs_transfer.sql
--
-- ΤΟ ΠΡΟΒΛΗΜΑ
--   Και τα 918 είδη των 14 ομάδων προμηθειών έχουν κενό technical_specs.
--   Έχουν μόνο standards. Κάθε μελέτη προμηθειών βγαίνει με άδεια τη στήλη
--   τεχνικών προδιαγραφών. Αντίθετα, οι 8 ομάδες Υπηρεσιών (178 είδη) είναι
--   ήδη πλήρεις και ΔΕΝ θίγονται από αυτή τη migration.
--
-- Η ΛΥΣΗ
--   Οι προδιαγραφές υπάρχουν πλήρεις στο παραγωγικό project. Η αντιστοίχιση
--   κωδικών ελέγχθηκε και είναι ακριβής: 918 προς 918, ανά ομάδα.
--   Μεταφέρονται μέσω CSV, χωρίς σύνδεση των δύο βάσεων μεταξύ τους.
--
-- ΣΕΙΡΑ ΕΚΤΕΛΕΣΗΣ
--   1. Εκτελέστε ΑΥΤΟ το αρχείο στο staging. Δημιουργεί τον πίνακα υποδοχής.
--   2. Στο ΠΑΡΑΓΩΓΙΚΟ, εκτελέστε το EXPORT_TECHNICAL_SPECS_FROM_PRODUCTION.sql
--      και κατεβάστε το αποτέλεσμα ως specs_export.csv (918 γραμμές).
--   3. Στο staging: Table Editor -> public.specs_import -> Import data from CSV.
--   4. Στο staging SQL Editor:  select * from public.apply_technical_specs_import();
--
-- ΑΣΦΑΛΕΙΑ
--   Η εφαρμογή γράφει ΜΟΝΟ σε είδη με κενό technical_specs. Δεν σβήνει και
--   δεν αντικαθιστά υπάρχον κείμενο. Είναι επαναλήψιμη: δεύτερη εκτέλεση
--   δεν αλλάζει τίποτε επιπλέον.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- 1. Πίνακας υποδοχής του CSV
--    Οι στήλες ονομάζονται ακριβώς όπως οι επικεφαλίδες του εξαγόμενου CSV,
--    ώστε ο εισαγωγέας του Supabase να τις αντιστοιχίσει αυτόματα.
-- ---------------------------------------------------------------------------
create table if not exists public.specs_import (
  group_code      text,
  material_code   text,
  technical_specs text
);

comment on table public.specs_import is
  'Προσωρινός πίνακας υποδοχής τεχνικών προδιαγραφών από CSV. Μπορεί να διαγραφεί μετά την επιτυχή εφαρμογή.';

alter table public.specs_import enable row level security;
revoke all on table public.specs_import from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Συνάρτηση εφαρμογής με αναφορά
--    Επιστρέφει μία γραμμή ανά ομάδα, ώστε να φαίνεται τι ενημερώθηκε,
--    τι ήταν ήδη συμπληρωμένο και τι δεν ταίριαξε.
-- ---------------------------------------------------------------------------
create or replace function public.apply_technical_specs_import()
returns table (
  "Ομάδα"              text,
  "Είδη στον κατάλογο" integer,
  "Ενημερώθηκαν"       integer,
  "Ήταν ήδη πλήρη"     integer,
  "Δεν βρέθηκαν"       integer,
  "Κατάσταση"          text
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_rows integer;
begin
  -- Έλεγχος δικαιώματος:
  --  • Μέσω εφαρμογής (υπάρχει JWT) απαιτείται ρόλος administrator.
  --  • Μέσω SQL Editor / service_role δεν υπάρχει JWT και η auth.uid() είναι
  --    κενή. Εκεί η πρόσβαση είναι ήδη προνομιακή, οπότε επιτρέπεται.
  --    Ο ρόλος anon δεν έχει EXECUTE σε αυτή τη συνάρτηση.
  if auth.uid() is not null and not public.app_is_admin() then
    raise exception using errcode = '42501',
      message = 'Μόνο administrator μπορεί να εφαρμόσει τις τεχνικές προδιαγραφές.';
  end if;

  select count(*) into v_rows from public.specs_import;
  if v_rows = 0 then
    raise exception 'Ο πίνακας public.specs_import είναι κενός. Εισαγάγετε πρώτα το specs_export.csv.';
  end if;

  -- Καθαρισμός τυχόν κενών γραμμών και περιττών διαστημάτων του CSV.
  delete from public.specs_import
  where coalesce(trim(material_code), '') = ''
     or coalesce(trim(technical_specs), '') = '';

  update public.specs_import
  set group_code      = trim(group_code),
      material_code   = trim(material_code),
      technical_specs = trim(technical_specs);

  -- Η ίδια η ενημέρωση: μόνο εκεί που λείπει το κείμενο.
  update public.materials m
  set technical_specs = s.technical_specs,
      updated_at      = now()
  from public.specs_import s
  join public.procurement_groups g on g.code = s.group_code
  where m.group_id = g.id
    and m.code = s.material_code
    and coalesce(trim(m.technical_specs), '') = '';

  return query
  with katalogos as (
    select g.code as gc, m.code as mc, m.technical_specs
    from public.materials m
    join public.procurement_groups g on g.id = m.group_id
    where g.domain = 'procurement'
  ),
  eisagogi as (
    select s.group_code as gc, s.material_code as mc from public.specs_import s
  )
  select
    k.gc::text,
    count(*)::integer,
    count(*) filter (
      where coalesce(trim(k.technical_specs), '') <> ''
        and exists (select 1 from eisagogi e where e.gc = k.gc and e.mc = k.mc)
    )::integer,
    count(*) filter (
      where coalesce(trim(k.technical_specs), '') <> ''
        and not exists (select 1 from eisagogi e where e.gc = k.gc and e.mc = k.mc)
    )::integer,
    count(*) filter (where coalesce(trim(k.technical_specs), '') = '')::integer,
    case when count(*) filter (where coalesce(trim(k.technical_specs), '') = '') = 0
         then '✅ πλήρης' else '⚠️ ελλιπής' end::text
  from katalogos k
  group by k.gc
  order by k.gc;
end;
$$;

revoke all on function public.apply_technical_specs_import() from public, anon;
grant execute on function public.apply_technical_specs_import() to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Βοηθητική όψη ελέγχου κάλυψης — μπορεί να κληθεί οποτεδήποτε
-- ---------------------------------------------------------------------------
create or replace view public.v_specs_coverage as
select
  g.domain                                                          as "Τομέας",
  g.code                                                            as "Ομάδα",
  count(*)::integer                                                 as "Είδη",
  count(*) filter (where coalesce(trim(m.technical_specs),'') <> '')::integer as "Με προδιαγραφές",
  count(*) filter (where coalesce(trim(m.standards),'') <> '')::integer       as "Με πρότυπα",
  round(avg(length(m.technical_specs)))::integer                    as "Μέσο μήκος"
from public.procurement_groups g
join public.materials m on m.group_id = g.id and m.is_active
group by g.domain, g.code, g.sort_order
order by g.sort_order;

revoke all on public.v_specs_coverage from anon;
grant select on public.v_specs_coverage to authenticated;

commit;

-- ============================================================================
-- ΜΕΤΑ ΤΗΝ ΕΙΣΑΓΩΓΗ ΤΟΥ CSV, ΕΚΤΕΛΕΣΤΕ:
--
--   select * from public.apply_technical_specs_import();
--
-- Αναμενόμενο: 14 γραμμές, όλες «✅ πλήρης», σύνολο ενημερώσεων 918.
--
-- Έλεγχος οποιαδήποτε στιγμή:
--   select * from public.v_specs_coverage;
--
-- Καθαρισμός μετά την επιτυχή εφαρμογή (προαιρετικό):
--   drop table public.specs_import;
-- ============================================================================
