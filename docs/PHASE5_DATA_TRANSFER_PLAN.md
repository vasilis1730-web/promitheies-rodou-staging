# Φάση 5 — Σχέδιο μεταφοράς δεδομένων

Προϋπόθεση: η καθαρή βάση (Φάση 1) έχει στηθεί σε **νέο project** με το
`00_FULL_INSTALL` και όλες τις migrations, ο κατάλογος έχει μεταφερθεί
(Φάση 2), και η τετράδα ομάδων Δ.Ε. έχει δημιουργηθεί με την απόφαση και το
ΑΔΑ (Φάση 3). Ο έλεγχος χωρητικότητας (Φάση 4) έχει ολοκληρωθεί:
**ΕΝΤΟΣ ΟΡΙΩΝ** — βλ. `docs/PHASE4_CAPACITY_RESULT.md`.

Η διαφορά σχήματος παράγεται αυτόματα:

```sh
node tools/schema-diff-legacy.mjs
```

και κατοχυρώνεται από το `tests/phase5-schema-diff.test.mjs`.

---

## 5α. Ταυτότητες χρηστών — ΠΡΩΤΑ

Οι 15 λογαριασμοί μεταφέρονται **με τα ίδια `id`** (και `encrypted_password`,
ώστε να μην αλλάξουν κωδικοί· όλοι είναι πάροχος `email`).

Κανένας πίνακας δεν έχει ξένο κλειδί προς `auth.users`, άρα η εισαγωγή **δεν
θα διαμαρτυρηθεί** αν τα `id` δεν ταιριάζουν. Το λάθος θα φανεί μετά:

- η RLS συγκρίνει `auth.uid()` με `profiles.id` — οι χρήστες δεν θα βλέπουν
  τα δικά τους αιτήματα,
- κάθε μελέτη, αίτημα και δελτίο χάνει τον συντάκτη του.

Στήλες που κρατούν ταυτότητα χρήστη: `profiles.id`, `unit_requests.created_by`,
`unit_requests.updated_by`, `request_lines.updated_by`, `saved_versions.created_by`,
`locked_studies.locked_by`, `export_jobs.created_by`, `tender_overrides.updated_by`,
`mo_orders.created_by`, `mo_orders.issued_by`.

Αν για οποιονδήποτε λόγο τα `id` αλλάξουν, χρειάζεται πίνακας αντιστοίχισης
παλιού → νέου και ανακατανομή **και των δέκα** στηλών.

## 5β. Σειρά μεταφοράς

Επιβάλλεται από τα ξένα κλειδιά:

```
profiles
  → unit_requests → request_lines
  → saved_versions
  → locked_studies
  → export_jobs
  → tender_overrides
mo_suppliers · mo_receivers · mo_projects
  → mo_contracts → mo_contract_items
  → mo_orders → mo_order_items
mo_counters
```

| Πίνακας | Εγγραφές |
|---|---:|
| profiles | 15 |
| unit_requests | 55 |
| request_lines | 182 |
| saved_versions | 282 |
| locked_studies | 6 |
| export_jobs | 17 |
| tender_overrides | 1 |
| mo_suppliers | 3 |
| mo_receivers | 0 |
| mo_projects | 1 |
| mo_contracts | 3 |
| mo_contract_items | 157 |
| mo_orders | 1 |
| mo_order_items | 1 |
| mo_counters | 3 |

## 5γ. Στήλες που ΠΡΕΠΕΙ να συμπληρωθούν

Δύο στήλες είναι `not null` χωρίς default και θα απορρίψουν την εισαγωγή αν
μείνουν κενές. Οι τιμές δεν επινοούνται: χρησιμοποιείται ο **ίδιος κανόνας**
που εφαρμόζει η migration `202608090003_v36_6_5_contract_pricing.sql` στα
υπάρχοντα δεδομένα.

| Πίνακας | Στήλη | Τιμή κατά τη μεταφορά |
|---|---|---|
| `mo_contracts` | `estimated_amount` | `coalesce(<net_total της πηγαίας μελέτης>, total_amount, 0)` |
| `mo_contract_items` | `estimated_unit_price` | `coalesce(unit_price, 0)` |

**Προσοχή στο constraint:** ισχύει `check (total_amount <= estimated_amount + 0.005)`
και ελέγχεται από trigger **και κατά την εισαγωγή**. Επαληθεύτηκε στο
παραγωγικό ότι και τα 3 συμβόλαια το περνούν με τον παραπάνω κανόνα
(`estimated_amount = total_amount` και στα τρία). Αν προστεθεί συμβόλαιο πριν
τη μετάπτωση, ο έλεγχος επαναλαμβάνεται.

## 5δ. Στήλες που πρέπει να τεθούν συνειδητά

Δεν εμποδίζουν την εισαγωγή, αλλά αν μείνουν κενές η εφαρμογή συμπεριφέρεται
λάθος:

| Πίνακας | Στήλη | Τιμή |
|---|---|---|
| `locked_studies` | `award_group_id` | Η ομάδα της Δ.Ε. από τη Φάση 3. **Χωρίς αυτό ο έλεγχος ορίου 30.000 € αγνοεί τη μελέτη.** Η αντιστοίχιση Δ.Ε. → ομάδα δίνεται από το `supabase/120_PHASE4_CAPACITY_CHECK.sql`. |
| `locked_studies` | `record_status` | `'active'` (είναι και το default) |

Οι υπόλοιπες νέες στήλες (`revision`, `created_by`/`updated_by`/`updated_at`
των μητρώων, `pricing_mode`, `discount_pct`, `quantity_scale`, πεδία ακύρωσης)
καλύπτονται από defaults.

## 5ε. Γνωστή απώλεια

`locked_studies.created_at` δεν υπάρχει στο νέο σχήμα. Η χρονική πληροφορία
διατηρείται στο `locked_at`, που είναι και το ουσιώδες πεδίο. Καμία άλλη
στήλη του παλιού δεν μένει χωρίς προορισμό.

## 5στ. Επαλήθευση μετά τη μεταφορά

1. Πλήθη εγγραφών ανά πίνακα ίδια με τον πίνακα της §5β.
2. `supabase/120_PHASE4_CAPACITY_CHECK.sql` στη **νέα** βάση: ίδια σύνολα με
   το `docs/PHASE4_CAPACITY_RESULT.md` (μέγιστο 7.258,06 €).
3. Καμία μελέτη με `award_group_id is null`.
4. Είσοδος με υπαρκτό λογαριασμό: ο χρήστης βλέπει τα δικά του αιτήματα.
5. `supabase/115_VERIFY_PHASE5_RLS_PRIVILEGE_HARDENING.sql` πράσινο.
6. Ένα δοκιμαστικό κλείδωμα μελέτης και μία έκδοση δελτίου.

## 5ζ. Τι ΔΕΝ μεταφέρεται

Οι πίνακες `esidis_folders`, `esidis_folder_log`, `yde_profiles`,
`yde_projects` ανήκουν σε άλλες εφαρμογές (βλ. ΒΗΜΑ4 §4.1α). Μένουν στο
παλιό project, το οποίο **δεν αποσύρεται**.
