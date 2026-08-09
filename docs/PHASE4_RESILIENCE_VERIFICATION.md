# Φάση 4 — Production Resilience Verification Matrix

Έκδοση στόχος: **v36.6.6**

## Καλυπτόμενοι κίνδυνοι

| Κίνδυνος | Μηχανισμός | Αυτοματοποιημένος έλεγχος |
|---|---|---|
| Διπλό πάτημα / επανάληψη μετά από χαμένη απάντηση | server-side `operation_id` idempotency | ίδιο operation ID δεν δημιουργεί δεύτερο request/study/order/import |
| Network failure μετά από πιθανό COMMIT | pending operation ID διατηρείται στον browser | transport failure → retry με ίδιο UUID και μεταγενέστερο manual retry με ίδιο UUID |
| Ταυτόχρονη επεξεργασία ίδιου πρόχειρου | `unit_requests.revision` + optimistic check | stale revision απορρίπτεται χωρίς last-writer-wins |
| Πρώτη ταυτόχρονη δημιουργία πρόχειρου | row lock στη Δημοτική Ενότητα + unique request context | σειριοποίηση πριν τη δημιουργία |
| Διπλό κλείδωμα μελέτης | idempotency + DB locks/unique constraints | μία κλειδωμένη μελέτη |
| Διπλή δημιουργία/έκδοση δελτίου | idempotency + order counter transaction | ένα δελτίο / ένας αριθμός |
| Διπλή δημιουργία σύμβασης | resilient contract entrypoint + unique study contract | ένα contract snapshot |
| Excel retry μετά από lost response | idempotency πάνω από single-use import token | token καταναλώνεται μία φορά, ίδιο αποτέλεσμα επιστρέφεται |
| Excel stale catalog | export token με catalog binding | import απορρίπτεται αν άλλαξε ο κατάλογος |
| Μερική αποτυχία στη μέση write RPC | PostgreSQL transaction semantics | forced failure αφήνει 0 partial order/idempotency residue |
| Session expiry | `onAuthStateChange` + session recovery mode | δεν γίνεται blind retry, pending operation ID διατηρείται |
| Επανασύνδεση | profile/permissions/schema revalidation χωρίς full `boot()` | το in-memory μη αποθηκευμένο draft δεν αντικαθίσταται |
| Legacy bypass | revoke EXECUTE στις παλιές critical RPCs | verifier + privilege regression test |
| Αντιγραφή draft σε άλλη Δ.Ε. | destination revision + idempotency | stale destination απορρίπτεται |
| Φόρτωση προτύπου | revision + idempotency | retry μία φορά, stale draft προστατεύεται |

## Critical resilient RPCs

- `save_unit_request_resilient_atomic`
- `lock_study_resilient_atomic`
- `save_contract_pricing_resilient_atomic`
- `save_order_resilient_atomic`
- `secure_import_catalog_request_resilient_atomic`
- `copy_unit_request_resilient_atomic`
- `load_study_template_resilient_atomic`

Οι legacy critical write RPCs παραμένουν εσωτερικά διαθέσιμες για σύνθεση συναλλαγών από `SECURITY DEFINER` functions, αλλά δεν είναι απευθείας εκτελέσιμες από τον browser role `authenticated`.

## Regression fixtures

Τα browser/JSDOM fixtures που προσομοιώνουν Supabase δηλώνουν πλέον schema **36.6.6** και περιμένουν τις resilient critical RPCs. Τα ιστορικά deployment-point tests εξακολουθούν να σταματούν ρητά στην έκδοση που ελέγχουν και δεν μετατρέπονται τεχνητά σε tests της τρέχουσας έκδοσης.

## Backup / recovery

Η τεχνική διαδικασία περιγράφεται στο `docs/PHASE4_DISASTER_RECOVERY.md`. Η εφαρμογή δεν αποθηκεύει database dumps ή credentials στο GitHub repository.

Η τελική επιχειρησιακή επιβεβαίωση backup απαιτεί έλεγχο στο Supabase Dashboard ότι υπάρχει πρόσφατο managed backup. Αυτό δεν μπορεί να αποδειχθεί από το repository CI.

## Deployment gate

1. Full GitHub CI σε καθαρό branch head.
2. Εφαρμογή migrations v36.6.6 στη staging βάση.
3. Εκτέλεση `supabase/113_VERIFY_V36_6_6_RESILIENCE.sql`.
4. Απαίτηση `phase4_db_ready = true`.
5. Browser smoke test σε v36.6.6.
6. Επιβεβαίωση πρόσφατου managed backup στο Supabase Dashboard.
7. Μόνο τότε merge/deploy.
