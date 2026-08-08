# Σειρά εγκατάστασης Supabase — v36.6.0 ADMIN STUDY MANAGEMENT

Το πακέτο προορίζεται αποκλειστικά για το project:

- Όνομα: `promitheies-rodou-staging`
- Project ref: `omncqldgtkdcjpqfwwlr`
- Region: West EU (Ireland)

Μην εκτελέσετε κανένα από τα παρακάτω SQL σε παραγωγικό ή μικτό project.

## Αναβάθμιση του υπάρχοντος staging v36.5.5 BULLETINS SCHEMA HOTFIX

Εφόσον έχει ήδη εφαρμοστεί το
`202608060003_fix_mo_orders_study_column.sql`, εκτελέστε **μόνο**:

1. `migrations/202608060004_admin_study_templates_and_purge.sql`
2. `104_VERIFY_ADMIN_STUDY_MANAGEMENT.sql` — μόνο αναγνωστικός έλεγχος

Μην επαναλάβετε το πλήρες installer και μην ξανατρέξετε το
`STAGING_SET_FIRST_ADMIN.sql`.

Αν το `202608060003_fix_mo_orders_study_column.sql` δεν έχει ακόμη εκτελεστεί,
πρέπει να προηγηθεί μαζί με το αναγνωστικό
`103_VERIFY_BULLETINS_SCHEMA_HOTFIX.sql`.

## Πλήρης εγκατάσταση σε νέο, κενό staging

1. `00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql`
2. `migrations/202608040001_award_groups.sql`
3. `migrations/202608050002_rls_immutable_audit.sql`
4. `migrations/202608050003_atomic_workflows.sql`
5. `migrations/202608050004_quantity_units_balances.sql`
6. `migrations/202608050005_xss_safe_excel.sql`
7. `migrations/202608050006_fixed_rhodes_award_groups.sql`
8. `migrations/202608050007_service_catalog.sql`
9. `migrations/202608050008_fix_save_request_status.sql`
10. `migrations/202608060001_fix_atavyros_unit_name.sql`
11. `migrations/202608060002_fix_south_rhodes_unit_name.sql`
12. `migrations/202608060003_fix_mo_orders_study_column.sql`
13. `migrations/202608060004_admin_study_templates_and_purge.sql`
14. `99_VERIFY_STAGING.sql` — μόνο αναγνωστικός έλεγχος καταλόγου
15. `100_VERIFY_SAVE_HOTFIX.sql` — μόνο αναγνωστικός έλεγχος αποθήκευσης
16. `101_VERIFY_ATAVYROS_HOTFIX.sql` — μόνο αναγνωστικός έλεγχος Δ.Ε. Αταβύρου
17. `102_VERIFY_GROUPS_HOTFIX.sql` — μόνο αναγνωστικός έλεγχος των 10 Δ.Ε.
18. `103_VERIFY_BULLETINS_SCHEMA_HOTFIX.sql` — μόνο αναγνωστικός έλεγχος δελτίων
19. `104_VERIFY_ADMIN_STUDY_MANAGEMENT.sql` — μόνο αναγνωστικός έλεγχος διαχείρισης μελετών

Κάθε αρχείο 1–13 περιβάλλεται από δική του συναλλαγή PostgreSQL. Αν ένα στάδιο
αποτύχει, δεν συνεχίζουμε στο επόμενο μέχρι να διορθωθεί και να ολοκληρωθεί
επιτυχώς το ίδιο στάδιο.

## Αναμενόμενο τελικό αποτέλεσμα

- Schema version: `36.6.0`
- 11 ενεργές μονάδες
- 14 ενεργές ομάδες προμηθειών
- 8 ενεργές ομάδες υπηρεσιών
- 918 ενεργά είδη προμηθειών
- 178 ενεργές εργασίες υπηρεσιών
- 1.096 ενεργές εγγραφές καταλόγου συνολικά
- 0 ενεργές υπηρεσίες χωρίς `standards`
- 10 Δημοτικές Ενότητες σε 4 σταθερές ομάδες
- `unit_requests.id`: `uuid`
- `app_excel_import_tokens.used_request_id`: `uuid`
- 0 χρήστες πριν από τη δημιουργία δοκιμαστικού λογαριασμού και 0
  κλειδωμένες μελέτες, συμβάσεις και δελτία υλικού
- 0 πίνακες `public` χωρίς ενεργό RLS
- Η `save_unit_request_atomic` χρησιμοποιεί τον enum τύπο `request_status`
  χωρίς μετατροπή από απλό `text`
- Οι γραφές `ΑΤΑΒΥΡΟΥ` και `ΑΤΤΑΒΥΡΟΥ` αναγνωρίζονται ως η ίδια Δ.Ε. της
  Ομάδας 4, χωρίς μεταβολή του καταλόγου
- Η πραγματική εγγραφή `ΝΟΤΙΑΣ ΡΟΔΟΥ` αναγνωρίζεται ως αυτοτελής Δ.Ε. της
  Ομάδας 3 και δεν συγχέεται με τη `ΡΟΔΟΥ` της Ομάδας 1
- Η τελική κατανομή των 10 Δ.Ε. ανά ομάδα είναι `1/3/3/3`
- Υπάρχει ο πίνακας `study_templates` με RLS και τέσσερις ατομικές RPC για
  αποθήκευση/φόρτωση/διαγραφή προτύπου και πλήρη διαγραφή μελέτης

Μετά τη δημιουργία και επιβεβαίωση του μοναδικού δοκιμαστικού χρήστη, εκτελείται
χωριστά το `STAGING_SET_FIRST_ADMIN.sql`. Το αρχείο αυτό δεν αποτελεί migration
και αποτυγχάνει σκόπιμα αν το project έχει περισσότερους χρήστες ή πραγματικές
κινήσεις.

## Πρόσθετες migrations v36.6.1 / v36.6.2

Εκτελούνται με τη σειρά, μετά τη `202608060004`:

| Αρχείο | Τι κάνει |
|---|---|
| `202608070001_fix_order_issue_and_purge_audit.sql` | Προσθέτει `mo_orders.issued_by`, επιτρέπει την κατάσταση `issued`, διευρύνει το `saved_versions.action` με `copy`/`import`/`cancel_lock`, και διατηρεί το ιστορικό στην πλήρη διαγραφή. Χωρίς αυτήν δεν αποθηκεύεται ούτε πρόχειρο δελτίο. |
| `202608070002_technical_specs_transfer.sql` | Πίνακας υποδοχής και συνάρτηση εφαρμογής τεχνικών προδιαγραφών από CSV. |
| `202608070003_security_hardening.sql` | Διορθώνει τα ευρήματα του security linter πριν από τη δημοσίευση του αποθετηρίου. |

Έλεγχος μετά την εκτέλεση: `105_VERIFY_ORDER_ISSUE_HOTFIX.sql` — και οι 12
γραμμές πρέπει να επιστρέψουν `✅ ΟΚ`.

Για τη μεταφορά προδιαγραφών: εκτελείται το
`EXPORT_TECHNICAL_SPECS_FROM_PRODUCTION.sql` στο project προέλευσης, το
αποτέλεσμα κατεβαίνει ως CSV, εισάγεται στον πίνακα `public.specs_import`
μέσω Table Editor, και εφαρμόζεται με
`select * from public.apply_technical_specs_import();`.

## Έκδοση

Η έκδοση εφαρμογής είναι `v36.6.1-order-issue-hotfix` και απαιτεί schema
`36.6.1`. Ο έλεγχος έκδοσης είναι **ισότητας**: αν η βάση αναβαθμιστεί χωρίς
να ανέβει το αντίστοιχο `index.html`, η εφαρμογή δεν ξεκινά καθόλου.

Οι τιμές του εισαγόμενου καταλόγου είναι ιστορικές προεπιλογές της παλιάς
εφαρμογής και δεν χρησιμοποιούνται ως τεκμήριο έρευνας αγοράς.
