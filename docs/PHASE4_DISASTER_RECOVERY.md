# Φάση 4 — Backup & Disaster Recovery Runbook

## Σκοπός

Η εφαρμογή «Προμήθειες Ρόδου» χρησιμοποιεί το Supabase/PostgreSQL ως κύριο μόνιμο αποθετήριο. Το παρόν runbook ορίζει το ελάχιστο ασφαλές μοντέλο αντιγράφων και επαναφοράς για επίσημη λειτουργία.

## 1. Managed backup του Supabase

Για Pro project, το Supabase δημιουργεί αυτόματα ημερήσια database backups και διατηρεί τα τελευταία 7 ημερών. Η κατάσταση ελέγχεται από **Supabase Dashboard → Database → Backups**.

Πηγή: https://supabase.com/docs/guides/platform/backups

### Υποχρεωτικός λειτουργικός έλεγχος

- Κάθε εργάσιμη ημέρα δεν απαιτείται χειροκίνητη ενέργεια.
- Μία φορά την εβδομάδα ο διαχειριστής επιβεβαιώνει ότι εμφανίζεται πρόσφατο επιτυχές backup στο Dashboard.
- Πριν από σημαντική schema migration ή release δημιουργείται επιπλέον logical backup εκτός GitHub.

## 2. Logical backup πριν από release

Το Supabase CLI υποστηρίζει χωριστό export roles / schema / data.

**ΠΟΤΕ** δεν αποθηκεύουμε connection string, database password ή backup δεδομένων μέσα στο δημόσιο repository ή σε public GitHub artifact.

Ενδεικτικά, σε ασφαλή workstation με το connection string σε προσωρινή environment variable:

```powershell
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
New-Item -ItemType Directory -Force -Path ".\secure-backups\$stamp" | Out-Null

supabase db dump --db-url $env:SUPABASE_DB_URL -f ".\secure-backups\$stamp\roles.sql" --role-only
supabase db dump --db-url $env:SUPABASE_DB_URL -f ".\secure-backups\$stamp\schema.sql"
supabase db dump --db-url $env:SUPABASE_DB_URL -f ".\secure-backups\$stamp\data.sql" --data-only --use-copy
```

Πηγή CLI: https://supabase.com/docs/reference/cli/supabase-orgs-list#supabase-db-dump

Μετά το dump:

1. Ελέγχεται ότι και τα τρία αρχεία είναι μη κενά.
2. Δημιουργείται SHA-256 checksum.
3. Το πακέτο κρυπτογραφείται και αποθηκεύεται σε ελεγχόμενο υπηρεσιακό/off-site χώρο.
4. Το μη κρυπτογραφημένο προσωρινό αντίγραφο διαγράφεται από το workstation όταν ολοκληρωθεί η ασφαλής μεταφορά.

## 3. Recovery Point Objective / Recovery Time

### Χωρίς PITR

Με ημερήσιο backup, σε καταστροφικό συμβάν μπορεί θεωρητικά να χαθούν οι αλλαγές μετά το τελευταίο διαθέσιμο backup. Για επίσημη χρήση αυτό σημαίνει ότι το αποδεκτό RPO πρέπει να αξιολογηθεί διοικητικά.

### Με PITR

Το Supabase προσφέρει Point-in-Time Recovery ως πρόσθετη υπηρεσία με επαναφορά σε πολύ λεπτότερο χρονικό σημείο. Για 7 ημέρες retention η τρέχουσα τιμολόγηση είναι περίπου $100/μήνα και απαιτεί τουλάχιστον Small compute add-on.

Πηγές:
- https://supabase.com/docs/guides/platform/backups#point-in-time-recovery
- https://supabase.com/docs/guides/platform/manage-your-usage/point-in-time-recovery

**Δεν ενεργοποιείται αυτόματα από την εφαρμογή.** Είναι επιχειρησιακή/οικονομική απόφαση του διαχειριστή του Supabase organization.

## 4. Διαδικασία incident recovery

Σε υποψία απώλειας ή αλλοίωσης δεδομένων:

1. **Freeze writes:** σταματά προσωρινά η καταχώριση νέων μελετών/συμβάσεων/δελτίων.
2. Καταγράφεται ακριβής ώρα και περιγραφή συμβάντος.
3. Εκτελείται ο τελευταίος διαθέσιμος read-only verifier της εφαρμογής.
4. Επιλέγεται restore point **πριν** από το συμβάν.
5. Προτιμάται πρώτα restore/clone σε ξεχωριστό project για έλεγχο, όταν η διαθέσιμη λειτουργία του Supabase το επιτρέπει.
6. Ελέγχονται:
   - `app_schema_version()`
   - χρήστες/profiles/permissions
   - 4 ομάδες Δ.Ε.
   - catalog counts
   - locked studies / contracts / orders
   - integrity verifiers.
7. Μόνο μετά τον έλεγχο αποφασίζεται production restore.
8. Μετά το restore εκτελείται smoke test login → κατάλογος → ανάγνωση πραγματικής μελέτης → σύμβαση → δελτία, χωρίς δοκιμαστική εγγραφή.

Η επαναφορά managed backup προκαλεί προσωρινή μη διαθεσιμότητα του project. Πηγή: https://supabase.com/docs/guides/platform/backups

## 5. Restore drill

Τουλάχιστον ανά τρίμηνο και πριν από μεγάλη παραγωγική αλλαγή:

- γίνεται logical dump,
- επαναφέρεται σε disposable/local ή ξεχωριστό Supabase project,
- εφαρμόζονται οι migrations του repository,
- εκτελούνται οι verifiers,
- καταγράφεται ότι schema και βασικά counts είναι συνεπή.

Δεν δοκιμάζουμε restore πάνω στην ενεργή επίσημη βάση μόνο για άσκηση.

## 6. Storage

Το τρέχον frontend δεν χρησιμοποιεί Supabase Storage API για μόνιμα αρχεία. Αν στο μέλλον προστεθούν uploads, πρέπει να προστεθεί ξεχωριστή πολιτική backup αντικειμένων, επειδή τα database backups του Supabase καλύπτουν metadata και όχι τα ίδια τα Storage objects.

Πηγή: https://supabase.com/docs/guides/platform/backups

## 7. Go-live checklist backup

- [ ] Pro project ενεργό.
- [ ] Πρόσφατο backup ορατό στο Database → Backups.
- [ ] Database password διαθέσιμο μόνο σε εξουσιοδοτημένο διαχειριστή.
- [ ] Δοκιμασμένο `supabase db dump` σε ασφαλές workstation.
- [ ] Κρυπτογραφημένος off-site χώρος αντιγράφων.
- [ ] Καταγεγραμμένος υπεύθυνος restore.
- [ ] Απόφαση αν απαιτείται PITR με βάση το αποδεκτό RPO.
- [ ] Τριμηνιαίο restore drill.
