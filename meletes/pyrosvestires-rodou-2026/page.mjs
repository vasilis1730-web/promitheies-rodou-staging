import { readFileSync, writeFileSync } from 'fs';
const items = JSON.parse(readFileSync('items.json','utf8'));
const eur = n => n.toLocaleString('el-GR',{minimumFractionDigits:2,maximumFractionDigits:2}) + ' €';
const esc = s => String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
const total = items.reduce((s,i)=>s+i.qty*i.price,0), vat=total*.24, grand=total*1.24;
const pieces = items.reduce((s,i)=>s+i.qty,0);

const LAW = [
 ['Κ.Υ.Α. 618/43/2005','Φ.Ε.Κ. Β΄ 52 / 20.01.2005','Το βασικό κείμενο: προϋποθέσεις διάθεσης στην αγορά, διαδικασίες συντήρησης, επανελέγχου και αναγόμωσης. Παραρτήματα ΙΙΙ (συντήρηση), IV (αναγόμωση), V (υδραυλική δοκιμή), VI, VII.'],
 ['Κ.Υ.Α. 17230/671/2005','Φ.Ε.Κ. Β΄ 1218 / 01.09.2005','Τροποποίηση και συμπλήρωση. Καθορίζει τις πινακίδες και το μητρώο συντήρησης–αναγόμωσης των αυτομάτων συστημάτων ξηράς κόνεως τοπικής εφαρμογής.'],
 ['Κ.Υ.Α. 140424/2021','Φ.Ε.Κ. Β΄ 6254 / 27.12.2021','Η πλέον πρόσφατη τροποποίηση της 618/43/2005 — αντικατάσταση του άρθρου 2 για την πρώτη διάθεση στην αγορά και τη σήμανση συμμόρφωσης.'],
 ['Πυροσβεστική Διάταξη 15/2022','Φ.Ε.Κ. Β΄ 5602 / 2022','Μέτρα και μέσα πυροπροστασίας — επάρκεια, χωροθέτηση και διατήρηση των φορητών μέσων σε ετοιμότητα.'],
 ['ΕΛΟΤ ΕΝ 3-7 · ΕΝ 1866-1','Ευρωπαϊκά πρότυπα','Φορητοί και τροχήλατοι πυροσβεστήρες αντιστοίχως — χαρακτηριστικά, απαιτήσεις επίδοσης, κατασβεστική ικανότητα.'],
 ['ΕΛΟΤ ΕΝ 615 · ΕΝ 1568 · ΕΝ ISO 5923','Ευρωπαϊκά πρότυπα','Κατασβεστικές σκόνες, αφρογόνα και διοξείδιο του άνθρακα.'],
 ['Οδηγία 2014/68/ΕΕ (Π.Δ. 91/2018) · ADR/ΤΠΕΔ','Εξοπλισμός υπό πίεση','Περιοδικός επανέλεγχος φιαλών CO₂ και φιαλών προωθητικού αερίου.'],
];
const PERIOD = [
 ['Ξηράς κόνεως — φορητοί','12 μήνες','5 έτη','10 έτη','20 έτη'],
 ['Ξηράς κόνεως — τροχήλατοι','12 μήνες','5 έτη','10 έτη','20 έτη'],
 ['Ξηράς κόνεως — οροφής / τοπικής εφαρμογής','12 μήνες','5 έτη','10 έτη','20 έτη'],
 ['Διοξειδίου του άνθρακα (CO₂)','12 μήνες <span class="fn">(με ζύγιση)</span>','10 έτη <span class="ast">*</span>','10 έτη <span class="fn">(ADR/ΤΠΕΔ)</span>','βάσει επανελέγχου φιάλης'],
 ['Αφρού AFFF / νερού','12 μήνες','5 έτη','10 έτη','20 έτη'],
 ['Υγρού χημικού — κατηγορίας F','12 μήνες','5 έτη','10 έτη','20 έτη'],
];
const RING = [['0','Άσπρο','#FFFFFF'],['1','Κίτρινο','#F2C230'],['2','Πορτοκαλί','#E8762C'],
 ['3','Καφέ','#6B4A2F'],['4','Πράσινο','#2E7D48'],['5','Μπλε','#2456A6'],['6','Μωβ','#6B3FA0'],
 ['7','Γκρι','#8A9099'],['8','Βυσσινί','#7B1E3A'],['9','Μαύρο','#1A1A1A']];
const COMMON = [
 'Πλήρης εκτόνωση και αποσυναρμολόγηση του πυροσβεστήρα.',
 'Άδειασμα της κόνεως, καθάρισμα και πρεσάρισμα του σώματος.',
 'Ενδελεχής εσωτερικός έλεγχος με <strong>φωτιστικό καθετήρα και καθρέφτη</strong> για διάβρωση, κοιλώματα, εγκοπές, χτυπήματα ή ζημιά της εσωτερικής επιφάνειας — με ιδιαίτερη προσοχή στα σημεία συγκόλλησης.',
 'Συντήρηση ή αντικατάσταση της βαλβίδας του κλείστρου, των παρεμβυσμάτων (O-rings), του σωλήνα κατάθλιψης, του ακροφυσίου, του μανομέτρου και της περόνης ασφαλείας.',
 'Γέμισμα εκ νέου με κόνι ίδιου τύπου και ονομαστικής ποσότητας, πιστοποιημένη κατά ΕΛΟΤ ΕΝ 615.',
 'Πλήρωση με νέο αδρανές αέριο (άζωτο) στην ονομαστική πίεση λειτουργίας.',
 'Έλεγχος στεγανότητας και παρακολούθηση επί ένα τουλάχιστον <strong>24ωρο</strong> για τυχόν απώλειες.',
 'Ζύγιση, τοποθέτηση δακτυλίου επανελέγχου, νέα ετικέτα και ενημέρωση του Μητρώου Συντήρησης &amp; Αναγόμωσης.',
];
const DUTIES = [
 ['Αναγνωρισμένη εταιρεία','Πιστοποιητικό Έγκρισης Κανονισμού Λειτουργίας κατά την Κ.Υ.Α. 618/43/2005, από διαπιστευμένο φορέα πιστοποίησης, σε ισχύ.'],
 ['Άδεια λειτουργίας','Άδεια του συνεργείου / εργαστηρίου αναγόμωσης από την αρμόδια Υπηρεσία της οικείας Περιφέρειας.'],
 ['Αρμόδιο άτομο','Οι εργασίες εκτελούνται αποκλειστικά από πιστοποιημένο αρμόδιο άτομο· κατατίθεται το πιστοποιητικό με ονοματεπώνυμο και αριθμό μητρώου.'],
 ['Διακριβωμένος εξοπλισμός','Εξοπλισμός υδραυλικής δοκιμής, ζύγισης και πλήρωσης με εν ισχύι πιστοποιητικά διακρίβωσης των οργάνων μέτρησης.'],
 ['Ασφαλιστική κάλυψη','Ασφαλιστήριο αστικής ευθύνης έναντι τρίτων για τις εκτελούμενες εργασίες.'],
];
const MATERIALS = [
 ['Ξηρά κόνις','Καινούργια, τύπου ABC με φωσφορικό αμμώνιο ≥ 40%, κατά ΕΛΟΤ ΕΝ 615, με πιστοποιητικό, παρτίδα και ημερομηνία παραγωγής. <strong>Απαγορεύεται</strong> η επαναχρησιμοποίηση της παλαιάς κόνεως.'],
 ['Διοξείδιο του άνθρακα','Καθαρότητα ≥ 99,5%, με δελτίο δεδομένων ασφαλείας.'],
 ['Προωθητικό αέριο','Ξηρό άζωτο υψηλής καθαρότητας.'],
 ['Υγρά F και αφρογόνα AFFF','Εγκεκριμένου τύπου, εντός ημερομηνίας λήξεως, με πιστοποιητικό και παρτίδα. Απαγορεύεται η ανάμιξη υγρών διαφορετικών κατασκευαστών.'],
 ['Ανταλλακτικά','Γνήσια ή ισοδύναμα εγκεκριμένου τύπου, συμβατά με τον εκάστοτε πυροσβεστήρα.'],
];
const DELIVER = [
 ['Μητρώο Συντήρησης &amp; Αναγόμωσης','Ανά πυροσβεστήρα: σειριακός αριθμός, τύπος, έτος κατασκευής, είδος εργασίας, ημερομηνία εκτέλεσης και ημερομηνία της επόμενης υποχρεωτικής ενέργειας.'],
 ['Πιστοποιητικά υδραυλικής δοκιμής','Για κάθε δοχείο που υποβλήθηκε σε επανέλεγχο δεκαετίας, με την πίεση δοκιμής και το αποτέλεσμα.'],
 ['Πιστοποιητικά υλικών','Κόνις κατά ΕΛΟΤ ΕΝ 615, CO₂, αφρογόνο και υγρό κατηγορίας F, με αναγραφή παρτίδας.'],
 ['Βεβαιώσεις καλής λειτουργίας','Για τα μόνιμα συστήματα τοπικής εφαρμογής και τους αυτόματους πυροσβεστήρες οροφής.'],
 ['Γνωστοποίηση απόσυρσης','Έγγραφη αναφορά των πυροσβεστήρων που κρίθηκαν ακατάλληλοι ή συμπλήρωσαν εικοσαετία, με τεκμηρίωση της καταστροφής τους.'],
];

// ── ομαδοποίηση ειδών ───────────────────────────────────────────────────────
const groups=[]; let g=null;
for(const it of items){ if(it.section){ g={title:it.section,rows:[]}; groups.push(g);} g.rows.push(it); }

const toc = [['antikeimeno','Αντικείμενο'],['plaisio','Θεσμικό πλαίσιο'],['anadohos','Υποχρεώσεις αναδόχου'],
 ['periodikotita','Περιοδικότητα'],['daktylios','Δακτύλιος επανελέγχου'],['koines','Κοινές εργασίες'],
 ['eidi','Τα 22 είδη'],['proypologismos','Προϋπολογισμός'],['paralavi','Παραλαβή & έλεγχος']];

const html = `<title>Αναγόμωση Πυροσβεστήρων Ρόδου</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Fira+Sans+Condensed:wght@500;600;700&family=Fira+Sans:wght@400;500;600&family=Literata:opsz,wght@7..72,400;7..72,500;7..72,600&display=swap&subset=greek,latin">
<style>
:root{
  --ground:#F4F6F8; --surface:#FFFFFF; --surface-2:#EDF1F5;
  --ink:#0F1720; --ink-2:#3D4A57; --ink-3:#697787;
  --line:#D6DEE6; --line-2:#C2CDD8;
  --navy:#1F4E79; --blue:#2E75B6; --blue-soft:#DDEBF7;
  --signal:#C1272D; --signal-soft:#FBE9E9;
  --shadow:0 1px 2px rgba(15,23,32,.05),0 8px 24px -16px rgba(15,23,32,.18);
  --display:"Fira Sans Condensed",-apple-system,Segoe UI,sans-serif;
  --body:"Literata",Georgia,serif;
  --ui:"Fira Sans",-apple-system,Segoe UI,sans-serif;
}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){
  --ground:#0D1319; --surface:#141C24; --surface-2:#1B252F;
  --ink:#E6ECF2; --ink-2:#B3C0CD; --ink-3:#8896A5;
  --line:#26323D; --line-2:#33424F;
  --navy:#8FC0E8; --blue:#6FA8DC; --blue-soft:#1B2C3D;
  --signal:#F08A8E; --signal-soft:#331A1C;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px -16px rgba(0,0,0,.7);
}}
:root[data-theme="dark"]{
  --ground:#0D1319; --surface:#141C24; --surface-2:#1B252F;
  --ink:#E6ECF2; --ink-2:#B3C0CD; --ink-3:#8896A5;
  --line:#26323D; --line-2:#33424F;
  --navy:#8FC0E8; --blue:#6FA8DC; --blue-soft:#1B2C3D;
  --signal:#F08A8E; --signal-soft:#331A1C;
  --shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px -16px rgba(0,0,0,.7);
}
*{box-sizing:border-box}
body{margin:0;background:var(--ground);color:var(--ink);
  font-family:var(--body);font-size:16px;line-height:1.65;
  -webkit-font-smoothing:antialiased;}
.wrap{max-width:1160px;margin:0 auto;padding:0 24px 96px;}

/* ── masthead ── */
.mast{border-bottom:3px solid var(--navy);padding:40px 0 24px;margin-bottom:40px;}
.crest{font-family:var(--ui);font-size:12px;font-weight:600;letter-spacing:.14em;
  text-transform:uppercase;color:var(--ink-3);margin:0 0 4px;}
.crest strong{color:var(--ink-2);font-weight:600;}
h1{font-family:var(--display);font-weight:700;font-size:clamp(30px,5.2vw,50px);
  line-height:1.05;letter-spacing:-.015em;margin:14px 0 8px;text-wrap:balance;color:var(--ink);}
.sub{font-family:var(--display);font-weight:500;font-size:clamp(16px,2.2vw,21px);
  color:var(--blue);margin:0 0 22px;letter-spacing:.01em;}
.facts{display:flex;flex-wrap:wrap;gap:0;border:1px solid var(--line);
  border-radius:3px;overflow:hidden;background:var(--surface);}
.fact{flex:1 1 150px;padding:13px 18px;border-right:1px solid var(--line);}
.fact:last-child{border-right:0}
.fact dt{font-family:var(--ui);font-size:11px;font-weight:600;letter-spacing:.11em;
  text-transform:uppercase;color:var(--ink-3);margin:0 0 3px;}
.fact dd{margin:0;font-family:var(--ui);font-weight:600;font-size:19px;
  color:var(--ink);font-variant-numeric:tabular-nums;line-height:1.2;}
.fact dd small{font-size:12px;font-weight:500;color:var(--ink-3);display:block;
  letter-spacing:.02em;margin-top:2px;}

/* ── layout ── */
.cols{display:grid;grid-template-columns:190px minmax(0,1fr);gap:52px;align-items:start;}
@media (max-width:900px){.cols{grid-template-columns:1fr;gap:28px}.toc{position:static!important;}}
.toc{position:sticky;top:24px;font-family:var(--ui);font-size:13.5px;}
.toc p{font-size:11px;font-weight:600;letter-spacing:.12em;text-transform:uppercase;
  color:var(--ink-3);margin:0 0 10px;padding-bottom:8px;border-bottom:1px solid var(--line);}
.toc ol{list-style:none;margin:0;padding:0;counter-reset:t;display:flex;flex-direction:column;gap:1px;}
.toc a{counter-increment:t;display:flex;gap:9px;text-decoration:none;color:var(--ink-2);
  padding:5px 8px;border-radius:3px;line-height:1.35;}
.toc a::before{content:counter(t);color:var(--ink-3);font-variant-numeric:tabular-nums;
  font-weight:600;font-size:11.5px;padding-top:2px;min-width:12px;}
.toc a:hover{background:var(--surface-2);color:var(--navy);}
.toc a:focus-visible{outline:2px solid var(--blue);outline-offset:1px;}

section{margin-bottom:52px;scroll-margin-top:20px;}
h2{font-family:var(--display);font-weight:700;font-size:clamp(21px,3vw,28px);
  letter-spacing:-.01em;margin:0 0 6px;color:var(--ink);text-wrap:balance;
  padding-bottom:9px;border-bottom:2px solid var(--navy);display:flex;
  align-items:baseline;gap:11px;}
h2 .n{font-size:14px;color:var(--blue);font-weight:600;font-variant-numeric:tabular-nums;}
.lede{color:var(--ink-2);margin:14px 0 22px;max-width:66ch;}
p{max-width:70ch}

/* ── generic definition list ── */
.dl{display:flex;flex-direction:column;gap:0;border:1px solid var(--line);
  border-radius:3px;background:var(--surface);overflow:hidden;}
.dl>div{display:grid;grid-template-columns:230px minmax(0,1fr);gap:22px;
  padding:14px 18px;border-bottom:1px solid var(--line);}
.dl>div:last-child{border-bottom:0}
@media (max-width:660px){.dl>div{grid-template-columns:1fr;gap:4px}}
.dl dt{font-family:var(--ui);font-weight:600;font-size:14.5px;color:var(--navy);margin:0;}
.dl dt em{display:block;font-style:normal;font-weight:500;font-size:12px;
  color:var(--ink-3);letter-spacing:.02em;margin-top:2px;}
.dl dd{margin:0;font-size:15px;color:var(--ink-2);}

/* ── tables ── */
.scroll{overflow-x:auto;border:1px solid var(--line);border-radius:3px;background:var(--surface);}
table{border-collapse:collapse;width:100%;font-family:var(--ui);font-size:14px;}
th{background:var(--navy);color:#fff;font-weight:600;font-size:11.5px;letter-spacing:.09em;
  text-transform:uppercase;text-align:left;padding:11px 14px;white-space:nowrap;}
td{padding:10px 14px;border-bottom:1px solid var(--line);color:var(--ink-2);vertical-align:top;}
tr:last-child td{border-bottom:0}
tbody tr:nth-child(even){background:var(--surface-2);}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;}
td.mid{text-align:center;font-variant-numeric:tabular-nums;}
td.first{font-weight:600;color:var(--ink);}
.fn{color:var(--ink-3);font-size:12px;}
.ast{color:var(--signal);font-weight:700;}
tr.sum td{background:var(--blue-soft);font-weight:600;color:var(--navy);border-bottom:1px solid var(--line-2);}
tr.sum.grand td{background:var(--navy);color:#fff;font-size:15.5px;}
:root:not([data-theme="light"]) tr.sum.grand td{color:var(--ground);}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) tr.sum.grand td{background:var(--blue);color:#0D1319;}}
:root[data-theme="dark"] tr.sum.grand td{background:var(--blue);color:#0D1319;}
.note{font-size:13.5px;color:var(--ink-3);margin-top:11px;max-width:74ch;font-family:var(--ui);}

/* ── ring swatches ── */
.rings{display:grid;grid-template-columns:repeat(auto-fit,minmax(104px,1fr));gap:10px;margin-top:6px;}
.ring{background:var(--surface);border:1px solid var(--line);border-radius:3px;
  padding:13px 10px;text-align:center;font-family:var(--ui);}
.ring .sw{width:42px;height:42px;border-radius:50%;margin:0 auto 9px;
  border:7px solid var(--c);background:transparent;box-shadow:inset 0 0 0 1px var(--line-2);}
.ring b{display:block;font-size:13px;font-weight:600;color:var(--ink);}
.ring span{font-size:11px;color:var(--ink-3);font-variant-numeric:tabular-nums;
  letter-spacing:.06em;text-transform:uppercase;}
.ring.now{border-color:var(--signal);box-shadow:0 0 0 2px var(--signal-soft);}
.ring.now b{color:var(--signal)}
.ring.now::after{content:"2026";display:block;margin-top:5px;font-size:10px;font-weight:700;
  letter-spacing:.1em;color:var(--signal);}

/* ── ordered work list ── */
.steps{counter-reset:s;list-style:none;margin:0;padding:0;
  display:flex;flex-direction:column;gap:9px;}
.steps li{counter-increment:s;display:grid;grid-template-columns:26px minmax(0,1fr);gap:13px;
  font-size:15px;color:var(--ink-2);max-width:76ch;}
.steps li::before{content:counter(s,decimal-leading-zero);font-family:var(--ui);font-weight:600;
  font-size:12px;color:var(--blue);padding-top:4px;font-variant-numeric:tabular-nums;}

/* ── item cards ── */
.grp{font-family:var(--display);font-weight:600;font-size:13px;letter-spacing:.1em;
  text-transform:uppercase;color:var(--navy);background:var(--blue-soft);
  padding:9px 15px;border-radius:3px;margin:34px 0 14px;}
.card{background:var(--surface);border:1px solid var(--line);border-radius:3px;
  padding:20px 22px;margin-bottom:12px;box-shadow:var(--shadow);}
.card header{display:flex;gap:14px;align-items:baseline;margin-bottom:12px;}
.card .aa{font-family:var(--ui);font-weight:700;font-size:13px;color:#fff;background:var(--navy);
  min-width:30px;height:26px;display:inline-flex;align-items:center;justify-content:center;
  border-radius:3px;font-variant-numeric:tabular-nums;flex:none;}
:root[data-theme="dark"] .card .aa{color:#0D1319;}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) .card .aa{color:#0D1319;}}
.card h3{font-family:var(--display);font-weight:600;font-size:19px;margin:0;
  color:var(--ink);line-height:1.25;text-wrap:balance;}
.meta{display:flex;flex-wrap:wrap;gap:0;border:1px solid var(--line);border-radius:3px;
  margin-bottom:14px;background:var(--surface-2);}
.meta div{flex:1 1 92px;padding:8px 13px;border-right:1px solid var(--line);font-family:var(--ui);}
.meta div:last-child{border-right:0}
.meta dt{font-size:10px;font-weight:600;letter-spacing:.1em;text-transform:uppercase;
  color:var(--ink-3);margin:0 0 1px;}
.meta dd{margin:0;font-size:15px;font-weight:600;color:var(--ink);font-variant-numeric:tabular-nums;}
.works{font-size:15px;color:var(--ink-2);margin:0 0 14px;max-width:none;}
.works b{font-family:var(--ui);font-size:11px;font-weight:600;letter-spacing:.1em;
  text-transform:uppercase;color:var(--ink-3);display:block;margin-bottom:3px;}
.std{font-family:var(--ui);font-size:12.5px;color:var(--ink-3);margin:0 0 12px;max-width:none;
  padding-left:11px;border-left:2px solid var(--line-2);}
.freq{background:var(--signal-soft);border-left:3px solid var(--signal);border-radius:0 3px 3px 0;
  padding:10px 14px;font-family:var(--ui);font-size:13.5px;color:var(--ink-2);}
.freq b{color:var(--signal);font-weight:600;letter-spacing:.02em;}

footer{margin-top:56px;padding-top:22px;border-top:1px solid var(--line);
  font-family:var(--ui);font-size:13px;color:var(--ink-3);display:flex;
  flex-wrap:wrap;gap:8px 26px;justify-content:space-between;}
a{color:var(--blue)}
</style>

<div class="wrap">
<header class="mast">
  <p class="crest">Ελληνική Δημοκρατία · Νομός Δωδεκανήσου · <strong>Δήμος Ρόδου</strong></p>
  <p class="crest">Διεύθυνση Τεχνικών Έργων &amp; Υποδομών — Τμήμα Προμηθειών</p>
  <h1>Αναγόμωση &amp; συντήρηση πυροσβεστήρων</h1>
  <p class="sub">Τεχνική έκθεση και τεχνικές προδιαγραφές · Έτος 2026 · CPV 24951230-6</p>
  <dl class="facts">
    <div class="fact"><dt>Είδη</dt><dd>22<small>κατηγορίες εργασιών</small></dd></div>
    <div class="fact"><dt>Πυροσβεστήρες</dt><dd>${pieces}<small>τεμάχια</small></dd></div>
    <div class="fact"><dt>Σύνολο</dt><dd>${eur(total)}<small>άνευ Φ.Π.Α.</small></dd></div>
    <div class="fact"><dt>Γενικό σύνολο</dt><dd>${eur(grand)}<small>με Φ.Π.Α. 24%</small></dd></div>
    <div class="fact"><dt>Κ.Α.</dt><dd>10-6261.0002<small>προϋπολογισμός Δήμου</small></dd></div>
  </dl>
</header>

<div class="cols">
<nav class="toc" aria-label="Περιεχόμενα">
  <p>Περιεχόμενα</p>
  <ol>${toc.map(([id,t])=>`<li><a href="#${id}">${t}</a></li>`).join('')}</ol>
</nav>

<main>
<section id="antikeimeno">
  <h2><span class="n">01</span>Αντικείμενο</h2>
  <p class="lede">Έλεγχος, συντήρηση, αναγόμωση και υδραυλική δοκιμή των φορητών και τροχήλατων πυροσβεστήρων όλων των τύπων, των αυτόματων πυροσβεστήρων οροφής και των μονίμων συστημάτων τοπικής εφαρμογής ξηράς κόνεως που είναι εγκατεστημένα στα κτίρια και τις εγκαταστάσεις του Δήμου Ρόδου.</p>
  <p>Η μελέτη περιλαμβάνει <strong>22 διακριτά είδη εργασιών</strong>, συνολικής ποσότητας <strong>${pieces} τεμαχίων</strong>. Οι εργασίες εκτελούνται υποχρεωτικά σύμφωνα με τις τελευταίες ισχύουσες εθνικές προδιαγραφές, και ιδίως την Κ.Υ.Α. 618/43/2005 όπως έχει τροποποιηθεί και ισχύει.</p>
</section>

<section id="plaisio">
  <h2><span class="n">02</span>Θεσμικό πλαίσιο &amp; πρότυπα</h2>
  <p class="lede">Το σύνολο των εργασιών διέπεται από τα ακόλουθα.</p>
  <div class="dl">${LAW.map(([a,b,c])=>`<div><dt>${a}<em>${b}</em></dt><dd>${c}</dd></div>`).join('')}</div>
</section>

<section id="anadohos">
  <h2><span class="n">03</span>Υποχρεώσεις του αναδόχου</h2>
  <p class="lede">Τυπικά προσόντα — επί ποινή αποκλεισμού.</p>
  <div class="dl">${DUTIES.map(([a,b])=>`<div><dt>${a}</dt><dd>${b}</dd></div>`).join('')}</div>
  <p class="lede" style="margin-top:26px">Υλικά αναγόμωσης.</p>
  <div class="dl">${MATERIALS.map(([a,b])=>`<div><dt>${a}</dt><dd>${b}</dd></div>`).join('')}</div>
  <p class="note">Παραλαβή και παράδοση με μεταφορικό μέσο, ευθύνη και δαπάνη του αναδόχου, εντός <strong>πέντε (5) εργασίμων ημερών</strong> από την έγγραφη διατακτική. Καθ’ όλη τη διάρκεια της εργασίας τοποθετείται πυροσβεστήρας αντικατάστασης ίδιου τύπου, ώστε να μην απομένει ακάλυπτη θέση πυροπροστασίας.</p>
</section>

<section id="periodikotita">
  <h2><span class="n">04</span>Υποχρεωτική περιοδικότητα</h2>
  <p class="lede">Κατά την Κ.Υ.Α. 618/43/2005, Παραρτήματα ΙΙΙ, IV και V. Οι χρόνοι μετρώνται από το έτος κατασκευής ή από την τελευταία αντίστοιχη εργασία.</p>
  <div class="scroll"><table>
    <thead><tr><th>Τύπος πυροσβεστήρα</th><th>Συντήρηση</th><th>Αναγόμωση</th><th>Υδραυλική δοκιμή</th><th>Απόσυρση</th></tr></thead>
    <tbody>${PERIOD.map(r=>`<tr><td class="first">${r[0]}</td>${r.slice(1).map(v=>`<td class="mid">${v}</td>`).join('')}</tr>`).join('')}</tbody>
  </table></div>
  <p class="note"><span class="ast">*</span> Στους πυροσβεστήρες CO₂ η αναγόμωση γίνεται υποχρεωτικά στη δεκαετία, ταυτόχρονα με την υδραυλική δοκιμή της φιάλης. Ανεξαρτήτως αυτού, κατά τον ετήσιο έλεγχο ο πυροσβεστήρας ζυγίζεται και αναγομώνεται <strong>άμεσα</strong> εφόσον η απώλεια μάζας υπερβαίνει το 10% της ονομαστικής γόμωσης.</p>
  <p class="note">Σε κάθε περίπτωση ο πυροσβεστήρας αναγομώνεται άμεσα μετά από οποιαδήποτε χρήση του, έστω και μερική, καθώς και όταν διαπιστωθεί πτώση πίεσης, φθορά ή απώλεια κατασβεστικού υλικού.</p>
</section>

<section id="daktylios">
  <h2><span class="n">05</span>Δακτύλιος επανελέγχου</h2>
  <p class="lede">Σε κάθε πυροσβεστήρα που ανοίγεται τοποθετείται στον λαιμό δακτύλιος από σκληρό και άκαμπτο πλαστικό — ώστε να μην μπορεί να αφαιρεθεί χωρίς άνοιγμα του κλείστρου — με <strong>ανάγλυφη την ημερομηνία ανοίγματος</strong>. Το χρώμα ορίζεται από το τελευταίο ψηφίο του έτους εργασίας.</p>
  <div class="rings">${RING.map(([d,n,c])=>`<div class="ring${d==='6'?' now':''}" style="--c:${c}"><div class="sw"></div><b>${n}</b><span>ψηφίο ${d}</span></div>`).join('')}</div>
  <p class="note">Για εργασίες εντός του <strong>2026 ο δακτύλιος είναι μωβ</strong>· εφόσον η σύμβαση επεκταθεί στο 2027, γκρι. Επιπλέον επικολλάται νέα ετικέτα με την επωνυμία και τον αριθμό αδείας της αναγνωρισμένης εταιρείας, το ονοματεπώνυμο και τον αριθμό πιστοποίησης του αρμοδίου ατόμου, το είδος της εργασίας, την ημερομηνία εκτέλεσης και την ημερομηνία της επόμενης υποχρεωτικής ενέργειας.</p>
</section>

<section id="koines">
  <h2><span class="n">06</span>Κοινές εργασίες αναγόμωσης ξηράς κόνεως</h2>
  <p class="lede">Για όλους τους πυροσβεστήρες ξηράς κόνεως η αναγόμωση συνίσταται υποχρεωτικώς στα εξής, κατά το Παράρτημα IV.</p>
  <ol class="steps">${COMMON.map(s=>`<li><span>${s}</span></li>`).join('')}</ol>
</section>

<section id="eidi">
  <h2><span class="n">07</span>Τα 22 είδη</h2>
  <p class="lede">Ένα προς ένα, με τις απαιτήσεις που τίθενται στον συντηρητή.</p>
  ${groups.map(gr=>`<div class="grp">${esc(gr.title)}</div>`+gr.rows.map(it=>`
  <article class="card">
    <header><span class="aa">${it.ordinal}</span><h3>${esc(it.name)}</h3></header>
    <dl class="meta">
      <div><dt>Ποσότητα</dt><dd>${it.qty} ${esc(it.unit)}</dd></div>
      <div><dt>Τιμή μονάδας</dt><dd>${eur(it.price)}</dd></div>
      <div><dt>Δαπάνη</dt><dd>${eur(it.qty*it.price)}</dd></div>
      <div><dt>CPV</dt><dd>${esc(it.cpv)}</dd></div>
    </dl>
    <p class="std">${esc(it.standards)}</p>
    <p class="works"><b>Απαιτούμενες εργασίες</b>${esc(it.specs)}</p>
    <p class="freq"><b>Υποχρεωτική περιοδικότητα:</b> ${esc(it.notes)}</p>
  </article>`).join('')).join('')}
</section>

<section id="proypologismos">
  <h2><span class="n">08</span>Ενδεικτικός προϋπολογισμός</h2>
  <div class="scroll"><table>
    <thead><tr><th>Α/Α</th><th>Περιγραφή</th><th>Μ.Μ.</th><th>Ποσότ.</th><th>Τιμή μον.</th><th>Δαπάνη</th></tr></thead>
    <tbody>
    ${items.map(it=>`<tr><td class="mid">${it.ordinal}</td><td>${esc(it.name)}</td><td class="mid">${esc(it.unit)}</td><td class="mid">${it.qty}</td><td class="num">${eur(it.price)}</td><td class="num">${eur(it.qty*it.price)}</td></tr>`).join('')}
    <tr class="sum"><td colspan="5" class="num">Σύνολο άνευ Φ.Π.Α.</td><td class="num">${eur(total)}</td></tr>
    <tr class="sum"><td colspan="5" class="num">Φ.Π.Α. 24%</td><td class="num">${eur(vat)}</td></tr>
    <tr class="sum grand"><td colspan="5" class="num">Γενικό σύνολο</td><td class="num">${eur(grand)}</td></tr>
    </tbody>
  </table></div>
  <p class="note">Η δαπάνη βαρύνει τον Κ.Α. 10-6261.0002 «Αναγόμωση πυροσβεστήρων Δήμου Ρόδου».</p>
</section>

<section id="paralavi">
  <h2><span class="n">09</span>Παραλαβή, ποιοτικός έλεγχος &amp; παραδοτέα</h2>
  <p class="lede">Με την ολοκλήρωση κάθε παρτίδας εργασιών ο ανάδοχος παραδίδει στην Υπηρεσία:</p>
  <div class="dl">${DELIVER.map(([a,b])=>`<div><dt>${a}</dt><dd>${b}</dd></div>`).join('')}</div>
  <p class="note">Η Υπηρεσία διατηρεί το δικαίωμα δειγματοληπτικού ελέγχου οποιουδήποτε πυροσβεστήρα — ζύγιση, έλεγχος πίεσης, έλεγχος σήμανσης και δακτυλίου. Σε περίπτωση πλημμελούς εργασίας ο ανάδοχος υποχρεούται σε άμεση επανάληψή της χωρίς πρόσθετη αποζημίωση, επιφυλασσομένων των ποινικών ρητρών του άρθρου 218 του Ν. 4412/2016.</p>
</section>

<footer>
  <span>Δήμος Ρόδου · Τεχνική έκθεση αναγόμωσης &amp; συντήρησης πυροσβεστήρων 2026</span>
  <span>Κ.Υ.Α. 618/43/2005 · 17230/671/2005 · 140424/2021</span>
</footer>
</main>
</div>
</div>`;

writeFileSync('report.html', html);
console.log('report.html:', html.length, 'bytes ·', groups.length, 'ομάδες ·', items.length, 'είδη');
