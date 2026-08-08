-- ============================================================================
-- ΕΞΑΓΩΓΗ ΤΕΧΝΙΚΩΝ ΠΡΟΔΙΑΓΡΑΦΩΝ ΠΡΟΜΗΘΕΙΩΝ
-- Αρχείο: supabase/EXPORT_TECHNICAL_SPECS_FROM_PRODUCTION.sql
--
-- ΠΟΥ ΕΚΤΕΛΕΙΤΑΙ: στο ΠΑΡΑΓΩΓΙΚΟ project «promitheies-dimou-rodou»
--                 (ref: hafaxrebjzootjzzqkzx), SQL Editor.
--
-- ΤΙ ΚΑΝΕΙ: ΜΟΝΟ ΑΝΑΓΝΩΣΗ. Δεν μεταβάλλει απολύτως τίποτε.
--           Επιστρέφει 918 γραμμές με τις τεχνικές προδιαγραφές των ειδών
--           του κανονικού καταλόγου προμηθειών.
--
-- ΜΕΤΑ ΤΗΝ ΕΚΤΕΛΕΣΗ: πατήστε «Download CSV» στο αποτέλεσμα και αποθηκεύστε
--                    το αρχείο ως specs_export.csv
--
-- ΣΗΜΕΙΩΣΗ: εξάγονται μόνο οι κωδικοί του κανονικού καταλόγου, μορφής
--           XXX-2026-NNN. Τα είδη που προήλθαν από εισαγωγές Excel
--           (IMP-…, HW-SHS-… κ.λπ.) ΔΕΝ εξάγονται, γιατί δεν υπάρχουν
--           στον κατάλογο του staging.
-- ============================================================================

select
  g.code                                        as group_code,
  m.code                                        as material_code,
  regexp_replace(m.technical_specs, '\s+', ' ', 'g') as technical_specs
from public.materials m
join public.procurement_groups g on g.id = m.group_id
where g.code not like 'SRV%'
  and m.code ~ '^[A-Z]{3}-2026-[0-9]{3}$'
  and coalesce(trim(m.technical_specs), '') <> ''
order by g.code, m.code;

-- ---------------------------------------------------------------------------
-- ΕΛΕΓΧΟΣ ΠΡΙΝ ΤΗΝ ΕΞΑΓΩΓΗ (προαιρετικό)
-- Το άθροισμα της στήλης «πλήθος» πρέπει να είναι 918.
-- ---------------------------------------------------------------------------
-- select g.code as ομάδα, count(*) as πλήθος
-- from public.materials m
-- join public.procurement_groups g on g.id = m.group_id
-- where g.code not like 'SRV%'
--   and m.code ~ '^[A-Z]{3}-2026-[0-9]{3}$'
--   and coalesce(trim(m.technical_specs), '') <> ''
-- group by g.code order by g.code;
