import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(new URL('..', import.meta.url).pathname);
const sourcePath = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.resolve(root, '..', 'upload', 'Supabase Snippet Untitled query.csv');
const migrationPath = path.join(root, 'supabase', 'migrations', '202608050007_service_catalog.sql');
const auditPath = path.join(root, 'SERVICE_CATALOG_AUDIT.md');

function readSingleCellCsv(filePath) {
  const text = fs.readFileSync(filePath, 'utf8').replace(/^\uFEFF/, '');
  const newline = text.indexOf('\n');
  if (newline < 0) throw new Error('Το CSV δεν περιέχει γραμμή δεδομένων.');
  const header = text.slice(0, newline).replace(/\r$/, '').trim();
  if (header !== 'service_catalog_export') throw new Error(`Μη αναμενόμενη κεφαλίδα CSV: ${header}`);
  const cell = text.slice(newline + 1).trim();
  if (!cell.startsWith('"') || !cell.endsWith('"')) throw new Error('Η τιμή JSON δεν είναι έγκυρο quoted CSV cell.');
  return JSON.parse(cell.slice(1, -1).replaceAll('""', '"'));
}

const exportData = readSingleCellCsv(sourcePath);
if (exportData.export_format !== 'promitheies-rodou-service-catalog-v1') {
  throw new Error(`Μη υποστηριζόμενη μορφή εξαγωγής: ${exportData.export_format}`);
}
if (exportData.groups.length !== 8 || exportData.items.length !== 178) {
  throw new Error(`Αναμένονταν 8 ομάδες και 178 εργασίες, βρέθηκαν ${exportData.groups.length}/${exportData.items.length}.`);
}

const BASE_STANDARDS = Object.freeze({
  SRV01: 'Π.Δ. 1/2013 · Κανονισμός (ΕΕ) 2024/573 · Εκτελεστικός Κανονισμός (ΕΕ) 2024/2215 · ΕΛΟΤ EN 378 (ή ισοδύναμο) · οδηγίες κατασκευαστή',
  SRV02: 'Υ.Α. 101195/17.09.2021 (Β΄ 4654), όπως τροποποιήθηκε και ισχύει · ΕΛΟΤ 60364 ή, κατά περίπτωση, ΕΛΟΤ HD 384/ΚΕΗΕ · σειρά ΕΛΟΤ EN 61557',
  SRV03: 'Ισχύουσες ΕΤΕΠ · ΕΛΟΤ EN 1436, EN 1871 και EN 1423/1424 για οριζόντια σήμανση · οδηγίες παραγωγού υλικών, κατά περίπτωση',
  SRV04: 'Ν. 1575/1985 και Π.Δ. 78/1988, όπως ισχύουν · οδηγίες και προδιαγραφές κατασκευαστή · εφαρμοστένοι κανονισμοί UNECE/ECE και πρότυπα ACEA/API, κατά περίπτωση · ισχύον πλαίσιο διαχείρισης αποβλήτων',
  SRV05: 'Κανονισμός (ΕΕ) 528/2012 · Ν. 3919/2011 · Κ.Υ.Α. 323/4883/2015 · εγκρίσεις βιοκτόνων ΥΠΑΑΤ · ΕΛΟΤ EN 16636 (ή ισοδύναμο), κατά περίπτωση',
  SRV06: 'Κ.Υ.Α. 618/43/2005, όπως τροποποιήθηκε με Κ.Υ.Α. 17230/671/2005 και Κ.Υ.Α. 140424/2021 · ΕΛΟΤ EN 3, EN 1866 και EN 671, κατά περίπτωση',
  SRV07: 'Κ.Υ.Α. Φ.Α/9.2/οικ.28425/1245/2008, όπως ισχύει · Κ.Υ.Α. 59210/2025 · άρθρο 137 Ν. 5317/2026 · ΕΛΟΤ EN 81-20/50, EN 81-28 και EN 81-40/41, κατά περίπτωση · οδηγίες κατασκευαστή',
  SRV08: 'Υ.Α. οικ.189533/2011 · Π.Δ. 114/2012 · ΕΛΟΤ EN 267, EN 676, EN 15378-1 και EN 442, κατά περίπτωση · οδηγίες κατασκευαστή'
});

const EXTRA_STANDARDS = Object.freeze({
  'SRV01-07': 'ΕΛΟΤ EN 15780',
  'SRV01-16': 'Οδηγία 2012/19/ΕΕ και ισχύον ελληνικό πλαίσιο ΑΗΗΕ',
  'SRV01-19': 'ΕΛΟΤ EN 12735-1',
  'SRV02-08': 'IEC 61082-1',
  'SRV02-09': 'ΕΛΟΤ EN IEC 61439',
  'SRV02-10': 'ΕΛΟΤ EN 61557-5',
  'SRV02-11': 'ΕΛΟΤ EN 61557-6',
  'SRV02-13': 'ΕΛΟΤ EN IEC 61439-3 · ΕΛΟΤ EN 60898-1 · ΕΛΟΤ EN 61008-1/61009-1',
  'SRV02-14': 'ΕΛΟΤ EN 60898-1',
  'SRV02-15': 'ΕΛΟΤ EN 61008-1/61009-1',
  'SRV02-18': 'σειρά ΕΛΟΤ EN 54',
  'SRV03-01': 'ΕΛΟΤ ΤΠ 1501-05-04-02-00 · ΕΛΟΤ EN 1436 · EN 1871 · EN 1423/1424',
  'SRV03-02': 'ΕΛΟΤ ΤΠ 1501-05-04-02-00 · ΕΛΟΤ EN 1436 · EN 1871 · EN 1423/1424',
  'SRV03-03': 'ΕΛΟΤ ΤΠ 1501-05-04-02-00 · ΕΛΟΤ EN 1436 · EN 1871 · EN 1423/1424',
  'SRV03-04': 'ΕΛΟΤ ΤΠ 1501-05-04-02-00 · ΕΛΟΤ EN 1436',
  'SRV03-05': 'ΕΛΟΤ ΤΠ 1501-05-04-02-00 · ΕΛΟΤ EN 1436',
  'SRV03-06': 'ΕΛΟΤ ΤΠ 1501-03-10-01-00/03-10-02-00, κατά περίπτωση',
  'SRV03-09': 'ΕΛΟΤ ΤΠ 1501-05-04-02-00 · ΕΛΟΤ EN 1436',
  'SRV03-10': 'ΕΛΟΤ ΤΠ 1501-05-04-01-00',
  'SRV03-13': 'ΕΛΟΤ ΤΠ 1501-03-10-02-00',
  'SRV03-14': 'ΕΛΟΤ ΤΠ 1501-03-10-02-00',
  'SRV03-15': 'ΕΛΟΤ ΤΠ 1501-03-10-03-00',
  'SRV03-16': 'ΕΛΟΤ ΤΠ 1501-03-10-03-00',
  'SRV03-22': 'ΕΛΟΤ ΤΠ 1501-05-04-03-00 · ΕΛΟΤ EN 1463-1',
  'SRV04-04': 'Κανονισμός UNECE R30 · Κανονισμός (ΕΕ) 2020/740',
  'SRV04-05': 'Κανονισμός UNECE R54 · Κανονισμός (ΕΕ) 2020/740',
  'SRV04-06': 'Κανονισμός UNECE R90',
  'SRV04-09': 'ΕΛΟΤ EN 50342',
  'SRV05-21': 'ΕΛΟΤ EN 16636 · αρχές HACCP',
  'SRV06-10': 'ΕΛΟΤ EN 1866',
  'SRV06-16': 'ΕΛΟΤ EN 1866',
  'SRV06-21': 'ΕΛΟΤ EN 671',
  'SRV07-04': 'ΕΛΟΤ EN 81-40/41',
  'SRV07-11': 'ΕΛΟΤ EN 81-20',
  'SRV07-12': 'ΕΛΟΤ EN 81-20',
  'SRV07-19': 'ΕΛΟΤ EN 81-28',
  'SRV08-01': 'ΕΛΟΤ EN 267 · ΕΛΟΤ EN 15378-1',
  'SRV08-02': 'ΕΛΟΤ EN 676 · ΕΛΟΤ EN 15378-1',
  'SRV08-04': 'Υ.Α. οικ.189533/2011 · ΕΛΟΤ EN 15378-1',
  'SRV08-12': 'ΕΛΟΤ EN 442'
});

const SUBCATEGORY_RANGES = Object.freeze({
  SRV01: [
    [/^SRV01-(0[1-9])$/, 'Προληπτική συντήρηση & έλεγχοι'],
    [/^SRV01-(1[0-5])$/, 'Επισκευές ψυκτικού κυκλώματος & αυτοματισμών'],
    [/^SRV01-(1[6-9])$/, 'Αποξήλωση, μεταφορά & εγκατάσταση'],
    [/^(SRV01-(2[0-5]))$/, 'Ανταλλακτικά & ειδικές επισκευές']
  ],
  SRV02: [
    [/^SRV02-(0[1-4]|06|07|20)$/, 'ΥΔΕ & πιστοποιήσεις'],
    [/^SRV02-(08|09|10|11|19)$/, 'Σχέδια, μετρήσεις & έλεγχοι'],
    [/^SRV02-(05|1[2-8])$/, 'Αποκαταστάσεις & ηλεκτρολογικές εργασίες']
  ],
  SRV03: [
    [/^SRV03-(0[1-5]|09|10|11|12|22)$/, 'Οριζόντια σήμανση & οδοδείκτες'],
    [/^SRV03-(06|07|08|1[3-9])$/, 'Χρωματισμοί & προστασία επιφανειών'],
    [/^SRV03-(20|21)$/, 'Αθλητικοί & σχολικοί χώροι']
  ],
  SRV04: [
    [/^SRV04-(01|18|19|22)$/, 'Διάγνωση, εργατοώρες & έκτακτη υποστήριξη'],
    [/^SRV04-(02|03|08|16|17|23)$/, 'Περιοδική συντήρηση'],
    [/^SRV04-(04|05|06|10|11)$/, 'Τροχοί, πέδηση & ανάρτηση'],
    [/^SRV04-(07|09|1[2-5]|20|21)$/, 'Μηχανικές, υδραυλικές & ηλεκτρικές επισκευές']
  ],
  SRV05: [
    [/^SRV05-(01|02|03|09|10|11|12|19|22)$/, 'Έντομα, τρωκτικά & παγίδες'],
    [/^SRV05-(05|06|08|20)$/, 'Καταπολέμηση κουνουπιών'],
    [/^SRV05-(04|14|15|16)$/, 'Απολυμάνσεις & καθαρισμοί'],
    [/^SRV05-17$/, 'Δεξαμενές νερού'],
    [/^SRV05-(07|13|18)$/, 'Ειδικές επεμβάσεις πανίδας'],
    [/^SRV05-21$/, 'Τεκμηρίωση & έλεγχος']
  ],
  SRV06: [
    [/^SRV06-(01|02|03|04|05|11|12|13)$/, 'Πυροσβεστήρες ξηράς κόνεως'],
    [/^SRV06-(06|07|14|15|16)$/, 'Πυροσβεστήρες CO₂'],
    [/^SRV06-(08|10)$/, 'Αυτόματοι & τροχήλατοι πυροσβεστήρες'],
    [/^SRV06-(09|17|18|19)$/, 'Νέοι πυροσβεστήρες'],
    [/^SRV06-20$/, 'Ανταλλακτικά πυροσβεστήρων'],
    [/^SRV06-(21|22)$/, 'Μόνιμα πυροσβεστικά μέσα']
  ],
  SRV07: [
    [/^SRV07-(01|02|04|06|07|21)$/, 'Τακτική συντήρηση'],
    [/^SRV07-(03|16|17)$/, 'Έλεγχοι, πιστοποίηση & μητρώο'],
    [/^SRV07-(05|08|09|1[0-5]|18|19|20)$/, 'Επισκευές & αναβαθμίσεις'],
    [/^SRV07-22$/, 'Απεγκλωβισμός & έκτακτη επέμβαση']
  ],
  SRV08: [
    [/^SRV08-(01|02|03|04|18|20|21|22)$/, 'Συντήρηση, καθαρισμός & έλεγχοι'],
    [/^SRV08-(05|06|07|08|09|10|11)$/, 'Καυστήρας & ανταλλακτικά'],
    [/^SRV08-(12|13|14|15|16|17|19)$/, 'Υδραυλικό δίκτυο θέρμανσης']
  ]
});

const ITEM_OVERRIDES = Object.freeze({
  'SRV02-03': {
    name: 'Επανέλεγχος ηλεκτρικής εγκατάστασης κατά ΕΛΟΤ 60364 ή το εφαρμοστέο παλαιότερο πλαίσιο',
    technical_specs: 'Επανέλεγχος υφιστάμενης εγκατάστασης με οπτική επιθεώρηση, δοκιμές και μετρήσεις κατά ΕΛΟΤ 60364 ή, για εγκατάσταση που έχει κατασκευαστεί με παλαιότερο κανονιστικό πλαίσιο, κατά ΕΛΟΤ HD 384/ΚΕΗΕ όπως επιτρέπει η Υ.Α. 101195/2021, όπως ισχύει. Χρησιμοποιούνται κατάλληλα και διακριβωμένα όργανα και παραδίδονται τα προβλεπόμενα πρωτόκολλα ελέγχου και πλήρης ΥΔΕ.'
  },
  'SRV02-18': {
    name: 'Λειτουργικός έλεγχος & τεχνική αναφορά εγκατάστασης πυρανίχνευσης'
  },
  'SRV05-07': {
    name: 'Προληπτική οφιοαπώθηση περιβάλλοντος χώρου με νόμιμα μη θανατηφόρα μέσα'
  },
  'SRV05-13': {
    name: 'Ασφαλής απομάκρυνση σφηκοφωλιάς ή συλλογή/μετεγκατάσταση σμήνους μελισσών',
    technical_specs: 'Επιτόπια εκτίμηση και ασφαλής επέμβαση. Για σφηκοφωλιά εφαρμόζεται μόνο εγκεκριμένο βιοκτόνο από κατάλληλο συνεργείο, εφόσον απαιτείται. Για σμήνος μελισσών προκρίνεται συλλογή και μετεγκατάσταση από κατάλληλο επαγγελματία χωρίς χρήση βιοκτόνου, εκτός αν υπάρχει άμεσος και τεκμηριωμένος κίνδυνος. Παραδοτέο: δελτίο επέμβασης με θέση, μέθοδο και αποτέλεσμα.'
  },
  'SRV05-18': {
    name: 'Εγκατάσταση μέτρων φυσικής οφιοπροστασίας και σφράγιση σημείων εισόδου',
    technical_specs: 'Αυτοψία και εφαρμογή μη θανατηφόρων μέτρων πρόληψης, όπως σφράγιση προσβάσεων, απομάκρυνση ασφαλών καταφυγίων και τοποθέτηση κατάλληλου φυσικού φραγμού όπου είναι τεχνικά εφικτό. Δεν γίνονται δεκτές μη τεκμηριωμένες συσκευές υπερήχων ως αποκλειστικό μέτρο προστασίας. Παραδοτέο: δελτίο με τα σημεία επέμβασης και φωτογραφική τεκμηρίωση.'
  },
  'SRV06-03': {
    name: 'Εργαστηριακός έλεγχος & υδραυλική δοκιμή πυροσβεστήρα ξηράς κόνεως 6 kg (δεκαετίας)',
    technical_specs: 'Εργαστηριακός έλεγχος δεκαετίας και υδραυλική δοκιμή του δοχείου στην προβλεπόμενη πίεση από αναγνωρισμένη εταιρεία/φορέα, με πλήρη επανέλεγχο, αντικατάσταση φθαρμένων εξαρτημάτων και κατασβεστικού υλικού όπου προβλέπεται, σήμανση και έκδοση βεβαίωσης σύμφωνα με την Κ.Υ.Α. 618/43/2005, όπως ισχύει.'
  },
  'SRV06-13': {
    name: 'Εργαστηριακός έλεγχος & υδραυλική δοκιμή πυροσβεστήρα ξηράς κόνεως 12 kg (δεκαετίας)',
    technical_specs: 'Εργαστηριακός έλεγχος δεκαετίας και υδραυλική δοκιμή του δοχείου στην προβλεπόμενη πίεση από αναγνωρισμένη εταιρεία/φορέα, με πλήρη επανέλεγχο, αντικατάσταση φθαρμένων εξαρτημάτων και κατασβεστικού υλικού όπου προβλέπεται, σήμανση και έκδοση βεβαίωσης σύμφωνα με την Κ.Υ.Α. 618/43/2005, όπως ισχύει.'
  },
  'SRV07-01': {
    name: 'Μηνιαίο πρόγραμμα συντήρησης ανελκυστήρα έως 6 στάσεις (2 επισκέψεις/μήνα σε δημοτικό κτίριο προσβάσιμο στο κοινό)'
  },
  'SRV07-02': {
    name: 'Μηνιαίο πρόγραμμα συντήρησης ανελκυστήρα 7–12 στάσεις (2 επισκέψεις/μήνα σε δημοτικό κτίριο προσβάσιμο στο κοινό)'
  },
  'SRV07-03': {
    name: 'Περιοδικός έλεγχος & πιστοποίηση ανελκυστήρα από αναγνωρισμένο φορέα, όταν απαιτείται'
  },
  'SRV07-06': {
    name: 'Μηνιαίο πρόγραμμα συντήρησης υδραυλικού ανελκυστήρα (2 επισκέψεις/μήνα σε δημοτικό κτίριο προσβάσιμο στο κοινό)'
  },
  'SRV07-07': {
    name: 'Ετήσιο πρόγραμμα συντήρησης ανελκυστήρα έως 6 στάσεων (24 επισκέψεις για δημοτικό κτίριο προσβάσιμο στο κοινό)',
    technical_specs: 'Ετήσιο πρόγραμμα τακτικής συντήρησης με είκοσι τέσσερις (24) επισκέψεις, δύο ανά μήνα, για ανελκυστήρα δημοτικού κτιρίου προσβάσιμου στο κοινό, σύμφωνα με το άρθρο 4 της Κ.Υ.Α. Φ.Α/9.2/οικ.28425/1245/2008. Περιλαμβάνονται οι προβλεπόμενοι έλεγχοι, καθαρισμοί, λιπάνσεις, ρυθμίσεις, ενημέρωση βιβλιαρίου και ενυπόγραφο δελτίο κάθε επίσκεψης.'
  },
  'SRV07-17': {
    name: 'Απογραφή/μεταβολή στο Εθνικό Μητρώο Απογραφής Ανελκυστήρων και υποστήριξη καταχώρισης',
    technical_specs: 'Έλεγχος φακέλου, συλλογή στοιχείων και υποστήριξη της απογραφής, διόρθωσης ή μεταβολής στο Εθνικό Μητρώο Απογραφής Ανελκυστήρων, καθώς και της χωριστής διαδικασίας καταχώρισης/ανανέωσης όπου απαιτείται. Παραδοτέο: αριθμός απογραφής, αποδεικτικό υποβολής και κατάλογος τυχόν εκκρεμών δικαιολογητικών.'
  }
});

function normalizeUnit(unit) {
  const value = String(unit || '').trim();
  if (value === 'τεμ') return 'τεμ.';
  return value;
}

function standardText(item) {
  return [BASE_STANDARDS[item.group_code], EXTRA_STANDARDS[item.code]].filter(Boolean).join(' · ');
}

function subcategoryFor(item) {
  for (const [pattern, label] of SUBCATEGORY_RANGES[item.group_code] || []) {
    if (pattern.test(item.code)) return label;
  }
  return item.subcategory || 'Λοιπές υπηρεσίες / εργασίες';
}

function updateLegacyReferences(text) {
  return String(text || '')
    .replaceAll('του ΚΑΝ (ΕΕ) 517/2014', 'του Κανονισμού (ΕΕ) 2024/573')
    .replaceAll('κατά ΚΑΝ (ΕΕ) 517/2014', 'κατά τον Κανονισμό (ΕΕ) 2024/573')
    .replaceAll('(ΚΑΝ (ΕΕ) 517/2014)', '(Κανονισμός (ΕΕ) 2024/573)')
    .replaceAll('κατά ΚΑΝ (ΕΕ) 2015/2067', 'κατά τον Εκτελεστικό Κανονισμό (ΕΕ) 2024/2215')
    .replaceAll('(ΚΑΝ (ΕΕ) 2015/2067)', '(Εκτελεστικός Κανονισμός (ΕΕ) 2024/2215)');
}

function elevatorMonthlySpec(item, original) {
  if (!['SRV07-01', 'SRV07-02', 'SRV07-06'].includes(item.code)) return original;
  const base = original.replace(/^Μηνιαία προληπτική συντήρηση/i, 'Πρόγραμμα τακτικής προληπτικής συντήρησης');
  return `${base} Για ανελκυστήρα σε δημοτικό κτίριο ή άλλο χώρο προσβάσιμο στο ευρύ κοινό εκτελούνται δύο (2) επισκέψεις ανά μήνα. Πριν από την πρώτη τακτική συντήρηση επιβεβαιώνεται και αναγράφεται στο δελτίο ο αριθμός απογραφής του Εθνικού Μητρώου.`;
}

const groups = exportData.groups
  .map(group => ({ ...group, sort_order: Number(group.sort_order), is_active: Boolean(group.is_active) }))
  .sort((a, b) => a.sort_order - b.sort_order);

const items = exportData.items
  .map(original => {
    const code = original.code.startsWith('IMP-') ? 'SRV01-25' : original.code;
    const initial = { ...original, code };
    const override = ITEM_OVERRIDES[code] || {};
    let technicalSpecs = override.technical_specs || updateLegacyReferences(original.technical_specs);
    technicalSpecs = elevatorMonthlySpec(initial, technicalSpecs);
    const name = override.name || original.name;
    return {
      ...initial,
      name,
      short_name: override.name ? name : (original.short_name || name),
      subcategory: subcategoryFor(initial),
      unit: normalizeUnit(original.unit),
      technical_specs: technicalSpecs,
      standards: standardText(initial),
      notes_for_tender: original.notes_for_tender,
      default_unit_price: Number(original.default_unit_price),
      sort_order: Number(original.sort_order),
      is_active: Boolean(original.is_active),
      ce_required: false
    };
  })
  .sort((a, b) => a.group_code.localeCompare(b.group_code) || a.sort_order - b.sort_order);

const codes = items.map(item => item.code);
if (new Set(codes).size !== items.length) throw new Error('Υπάρχουν διπλοί κωδικοί μετά την κανονικοποίηση.');
if (items.some(item => !item.standards || !item.technical_specs || !item.cpv || !item.unit)) {
  throw new Error('Υπάρχει εργασία χωρίς υποχρεωτικό τεχνικό πεδίο.');
}
if (items.some(item => /517\/2014|2015\/2067|πενταετίας\).*υδραυλ/i.test(`${item.name} ${item.technical_specs}`))) {
  throw new Error('Παρέμεινε καταργημένη ή λανθασμένη κανονιστική αναφορά.');
}

const sql = value => value == null ? 'null' : `'${String(value).replaceAll("'", "''")}'`;
const bool = value => value ? 'true' : 'false';
const num = value => Number.isFinite(Number(value)) ? String(Number(value)) : 'null';

const groupValues = groups.map(group => `  (${sql(group.code)}, ${sql(group.name)}, ${sql(group.short_name || group.name)}, ${num(group.sort_order)}, 'service', ${bool(group.is_active)})`).join(',\n');
const itemValues = items.map(item => [
  sql(item.group_code), sql(item.code), sql(item.name), sql(item.short_name), sql(item.subcategory),
  sql(item.unit), sql(item.cpv), sql(item.technical_specs), sql(item.standards), bool(false),
  sql(item.notes_for_tender), num(item.default_unit_price), bool(item.is_active), num(item.sort_order)
].join(', ')).map(row => `  (${row})`).join(',\n');

const migration = `-- v36.5.5 — Ελεγχόμενη εισαγωγή καταλόγου Υπηρεσιών στο STAGING.
-- Πηγή: αναγνωστική εξαγωγή της προηγούμενης εφαρμογής (${exportData.generated_at}).
-- Το SQL προορίζεται αποκλειστικά για το promitheies-rodou-staging.
-- Δεν εισάγει το legacy tender override SRV01, επειδή περιέγραφε προμήθεια νέων
-- κλιματιστικών και όχι υπηρεσία συντήρησης.

begin;

create table if not exists public.app_catalog_migrations (
  id text primary key,
  source_format text not null,
  source_generated_at timestamptz,
  group_count integer not null,
  item_count integer not null,
  metadata jsonb not null default '{}'::jsonb,
  applied_at timestamptz not null default now()
);

alter table public.app_catalog_migrations enable row level security;
revoke all on public.app_catalog_migrations from public, anon, authenticated;

do $$
declare
  v_version text;
begin
  select public.app_schema_version() into v_version;
  if v_version not in ('36.5.1', '36.5.5') then
    raise exception 'Απαιτείται schema 36.5.1 πριν από την εισαγωγή υπηρεσιών. Βρέθηκε: %', v_version;
  end if;

  if exists (select 1 from public.app_catalog_migrations where id = '202608050007_service_catalog') then
    return;
  end if;

  if (select count(*) from public.municipal_units where is_active) <> 11 then
    raise exception 'Ο έλεγχος ασφαλείας απέτυχε: αναμένονται 11 ενεργές μονάδες στο κενό staging.';
  end if;
  if (select count(*) from public.procurement_groups where domain = 'procurement' and is_active) <> 14 then
    raise exception 'Ο έλεγχος ασφαλείας απέτυχε: αναμένονται 14 ενεργές ομάδες προμηθειών.';
  end if;
  if (
    select count(*)
    from public.materials m
    join public.procurement_groups g on g.id = m.group_id
    where g.domain = 'procurement' and m.is_active
  ) <> 918 then
    raise exception 'Ο έλεγχος ασφαλείας απέτυχε: αναμένονται 918 ενεργά είδη προμηθειών.';
  end if;
  if exists (select 1 from public.procurement_groups where domain = 'service') then
    raise exception 'Υπάρχουν ήδη ομάδες υπηρεσιών χωρίς καταγεγραμμένη migration. Η εισαγωγή ακυρώθηκε χωρίς αλλαγές.';
  end if;
  if exists (select 1 from public.materials where code = any(array[${items.map(item => sql(item.code)).join(', ')}])) then
    raise exception 'Υπάρχει ήδη κωδικός εργασίας SRV/legacy στο staging. Η εισαγωγή ακυρώθηκε χωρίς αλλαγές.';
  end if;
end
$$;

insert into public.procurement_groups (code, name, short_name, sort_order, domain, is_active)
select * from (values
${groupValues}
) as x(code, name, short_name, sort_order, domain, is_active)
where not exists (
  select 1 from public.app_catalog_migrations where id = '202608050007_service_catalog'
);

with service_items(group_code, code, name, short_name, subcategory, unit, cpv, technical_specs, standards, ce_required, notes_for_tender, default_unit_price, is_active, sort_order) as (
  values
${itemValues}
)
insert into public.materials (
  group_id, code, name, short_name, subcategory, unit, quantity_scale, cpv,
  technical_specs, standards, ce_required, notes_for_tender,
  default_unit_price, is_active, sort_order
)
select
  g.id, x.code, x.name, x.short_name, x.subcategory, x.unit,
  public.app_unit_default_scale(x.unit), x.cpv, x.technical_specs, x.standards,
  x.ce_required, x.notes_for_tender, x.default_unit_price, x.is_active, x.sort_order
from service_items x
join public.procurement_groups g on g.code = x.group_code and g.domain = 'service'
where not exists (
  select 1 from public.app_catalog_migrations where id = '202608050007_service_catalog'
);

insert into public.material_aliases (material_id, alias, source_note)
select m.id, 'IMP-29-1783067314938-1', 'Παλαιός αυτόματος κωδικός της προηγούμενης εφαρμογής'
from public.materials m
where m.code = 'SRV01-25'
  and not exists (
    select 1 from public.app_catalog_migrations where id = '202608050007_service_catalog'
  )
on conflict (material_id, alias) do nothing;

insert into public.app_catalog_migrations (
  id, source_format, source_generated_at, group_count, item_count, metadata
) values (
  '202608050007_service_catalog',
  ${sql(exportData.export_format)},
  ${sql(exportData.generated_at)}::timestamptz,
  8,
  178,
  jsonb_build_object(
    'source', ${sql(exportData.source)},
    'pricing_status', 'legacy_defaults_not_contract_verified',
    'standards_enriched', true,
    'legacy_tender_override_imported', false,
    'canonicalized_legacy_code', 'IMP-29-1783067314938-1 -> SRV01-25'
  )
)
on conflict (id) do nothing;

create or replace function public.app_schema_version()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select '36.5.5'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

do $$
declare
  v_groups integer;
  v_items integer;
  v_without_standards integer;
begin
  select count(*) into v_groups
  from public.procurement_groups
  where domain = 'service' and is_active;

  select count(*), count(*) filter (where nullif(btrim(m.standards), '') is null)
  into v_items, v_without_standards
  from public.materials m
  join public.procurement_groups g on g.id = m.group_id
  where g.domain = 'service' and m.is_active;

  if v_groups <> 8 or v_items <> 178 or v_without_standards <> 0 then
    raise exception 'Αποτυχία επαλήθευσης καταλόγου υπηρεσιών: groups=%, items=%, without_standards=%',
      v_groups, v_items, v_without_standards;
  end if;
  if exists (
    select 1
    from public.materials m
    join public.procurement_groups g on g.id = m.group_id
    where g.domain = 'service'
      and (coalesce(m.technical_specs, '') ~ '517/2014|2015/2067'
           or coalesce(m.name, '') ~* 'υδραυλ.*πενταετ')
  ) then
    raise exception 'Παρέμεινε παλιά ή λανθασμένη κανονιστική αναφορά στον κατάλογο υπηρεσιών.';
  end if;
end
$$;

commit;
`;

const groupCounts = Object.fromEntries(groups.map(group => [group.code, items.filter(item => item.group_code === group.code).length]));
const correctionRows = [
  ['SRV01', 'Αντικατάσταση 517/2014 και 2015/2067 με 2024/573 και 2024/2215.'],
  ['SRV02', 'Επικαιροποίηση ΥΔΕ σε Υ.Α. 101195/2021 όπως ισχύει και ορθή χρήση ΕΛΟΤ 60364/HD 384/ΚΕΗΕ κατά περίπτωση.'],
  ['SRV03', 'Αντιστοίχιση στις ισχύουσες ΕΤΕΠ και στα EN 1436, 1871, 1423/1424 και 1463-1.'],
  ['SRV05', 'Διαχωρισμός σφηκών/μελισσών και αντικατάσταση της αποκλειστικής χρήσης υπερήχων με τεκμηριωμένα φυσικά μέτρα οφιοπροστασίας.'],
  ['SRV06', 'Διόρθωση υδραυλικής δοκιμής από πενταετία σε δεκαετή εργαστηριακό έλεγχο και προσθήκη Κ.Υ.Α. 140424/2021.'],
  ['SRV07', 'Δύο συντηρήσεις τον μήνα για χώρους προσβάσιμους στο κοινό και απαίτηση αριθμού απογραφής μετά τον Ν. 5317/2026.'],
  ['Όλες', 'Δομημένο πεδίο standards, υποκατηγορίες και σταθεροποίηση του κωδικού IMP… σε SRV01-25.']
];

const audit = `# Έλεγχος και μετασχηματισμός καταλόγου Υπηρεσιών — v36.5.5

## Αποτέλεσμα

- Πηγή: \`${path.basename(sourcePath)}\`
- Μορφή πηγής: \`${exportData.export_format}\`
- Χρόνος εξαγωγής: \`${exportData.generated_at}\`
- Ομάδες: **8**
- Εργασίες: **178 ενεργές**
- Διπλοί κωδικοί: **0**
- Εργασίες χωρίς CPV/μονάδα/τιμή/τεχνική περιγραφή: **0**
- Εργασίες χωρίς δομημένο πεδίο standards μετά τον εμπλουτισμό: **0**

| Κωδικός | Ομάδα | Εργασίες |
|---|---|---:|
${groups.map(group => `| ${group.code} | ${group.name} | ${groupCounts[group.code]} |`).join('\n')}

## Κρίσιμες διορθώσεις

| Πεδίο | Διόρθωση |
|---|---|
${correctionRows.map(([code, note]) => `| ${code} | ${note} |`).join('\n')}

Το legacy override \`SRV01\` **δεν εισάγεται**, επειδή περιγράφει κυρίως προμήθεια νέων κλιματιστικών (ενεργειακή ετικέτα, EPREL, εγγύηση συμπιεστή) και όχι υπηρεσία συντήρησης. Η v36.5.5 περιλαμβάνει νέο αυτοτελές πρότυπο υπηρεσίας συντήρησης κλιματισμού.

## Κατάσταση τιμών

Οι 178 τιμές μεταφέρονται ως **ιστορικές προεπιλεγμένες τιμές της παλιάς εφαρμογής**. Η εξαγωγή δεν περιέχει αριθμούς συμβάσεων, ΑΔΑΜ, παρατηρήσεις τιμών ή άλλα αποδεικτικά. Συνεπώς:

- δεν χαρακτηρίζονται ως συμβασιοποιημένες,
- δεν αποτελούν αυτοτελή έρευνα αγοράς,
- πριν από δημοσίευση μελέτης πρέπει να αντικαθίστανται ή να επιβεβαιώνονται με τεκμηριωμένες παρατηρήσεις τιμών.

## Επίσημες πηγές επικαιροποίησης

- F-gas: https://eur-lex.europa.eu/eli/reg/2024/573/oj
- Πιστοποίηση ψυκτικών: https://eur-lex.europa.eu/eli/reg_impl/2024/2215/oj
- ΥΔΕ και ισχύουσες αποφάσεις: https://www.deddie.gr/el/aitimata-exypiretisis/ypefthyni-dilosi-egkatastati-yde/
- Ισχύουσες ΕΤΕΠ: https://www.ggde.gr/index.php?id=8415&option=com_k2&view=item
- Επιχειρήσεις επαγγελματικής χρήσης βιοκτόνων: https://www.minagric.gr/for-farmer-2/entomatroktika
- Πυροσβεστήρες — ενημέρωση Πυροσβεστικού Σώματος: https://www.fireservice.gr/documents/20184/178334/
- Εθνικό Μητρώο Απογραφής Ανελκυστήρων: https://elevator.mindev.gov.gr/
- Υ.Α. 189533/2011 για σταθερές εστίες καύσης: https://www.elinyae.gr/ethniki-nomothesia/ya-arith-prot-oik-1895332011-fek-2654b-9112011

## Έλεγχος εισαγωγής

Η migration:

1. εκτελείται σε μία συναλλαγή,
2. ελέγχει schema \`36.5.1\`, 11 μονάδες, 14 ομάδες προμηθειών και 918 ενεργά είδη,
3. ακυρώνεται χωρίς αλλαγές αν υπάρχουν μη καταγεγραμμένες ομάδες υπηρεσιών ή συγκρουόμενοι κωδικοί,
4. εισάγει 8 ομάδες και 178 εργασίες,
5. επαληθεύει ότι καμία ενεργή εργασία δεν έμεινε χωρίς standards,
6. αναβαθμίζει το schema σε \`36.5.5\`,
7. είναι ασφαλής σε δεύτερη εκτέλεση: αναγνωρίζει τη migration και δεν διπλασιάζει εγγραφές.
`;

fs.writeFileSync(migrationPath, migration, 'utf8');
fs.writeFileSync(auditPath, audit, 'utf8');

console.log(JSON.stringify({
  migrationPath,
  auditPath,
  groups: groups.length,
  items: items.length,
  activeItems: items.filter(item => item.is_active).length,
  standardsMissing: items.filter(item => !item.standards).length
}, null, 2));
