import { readFileSync } from 'fs';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const pkg = require('docx');
const { Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType, Table, TableRow,
        TableCell, WidthType, ShadingType, BorderStyle, PageOrientation, Header, Footer,
        PageNumber, TabStopType, LevelFormat, convertInchesToTwip } = pkg;

const items = JSON.parse(readFileSync('items.json','utf8'));
const W = 9638;                      // ωφέλιμο πλάτος σελίδας A4 με περιθώρια 2 cm
const NAVY = '1F4E79', BLUE = '2E75B6', LIGHT = 'DDEBF7', ALT = 'F2F7FC';
const FONT = 'Arial';

const eur = n => n.toLocaleString('el-GR',{minimumFractionDigits:2,maximumFractionDigits:2}) + ' €';
const total = items.reduce((s,i)=>s+i.qty*i.price,0);
const vat = total*0.24, grand = total*1.24;

const P = (text,o={}) => new Paragraph({
  alignment:o.align, spacing:{before:o.before??0,after:o.after??100,line:o.line??276},
  indent:o.indent, border:o.border,
  children:[new TextRun({text,bold:o.bold,italics:o.italics,size:o.size??20,
    color:o.color,font:FONT})]
});
const H = (text,level,o={}) => new Paragraph({
  heading:level, spacing:{before:o.before??240,after:o.after??120},
  children:[new TextRun({text,bold:true,size:o.size??24,color:o.color??NAVY,font:FONT})]
});
const cell = (text,o={}) => new TableCell({
  width:{size:o.w,type:WidthType.DXA},
  shading:o.fill?{type:ShadingType.CLEAR,fill:o.fill,color:'auto'}:undefined,
  margins:{top:60,bottom:60,left:80,right:80},
  verticalAlign:'center',
  children:[new Paragraph({alignment:o.align,spacing:{after:0,line:240},
    children:[new TextRun({text:String(text),bold:o.bold,size:o.size??18,
      color:o.color,font:FONT})]})]
});
const table = (cols,rows) => new Table({
  columnWidths:cols, width:{size:W,type:WidthType.DXA},
  borders:{top:{style:BorderStyle.SINGLE,size:4,color:'BFBFBF'},
           bottom:{style:BorderStyle.SINGLE,size:4,color:'BFBFBF'},
           left:{style:BorderStyle.SINGLE,size:4,color:'BFBFBF'},
           right:{style:BorderStyle.SINGLE,size:4,color:'BFBFBF'},
           insideHorizontal:{style:BorderStyle.SINGLE,size:2,color:'BFBFBF'},
           insideVertical:{style:BorderStyle.SINGLE,size:2,color:'BFBFBF'}},
  rows
});
const RULE = new Paragraph({spacing:{after:160},
  border:{bottom:{style:BorderStyle.SINGLE,size:6,color:BLUE}},children:[]});

const body = [];

// ───────────────────────── ΕΞΩΦΥΛΛΟ / ΤΙΤΛΟΣ ─────────────────────────
body.push(P('ΕΛΛΗΝΙΚΗ ΔΗΜΟΚΡΑΤΙΑ',{bold:true,align:AlignmentType.CENTER,size:22,after:0}));
body.push(P('ΝΟΜΟΣ ΔΩΔΕΚΑΝΗΣΟΥ — ΔΗΜΟΣ ΡΟΔΟΥ',{bold:true,align:AlignmentType.CENTER,size:22,after:0}));
body.push(P('ΔΙΕΥΘΥΝΣΗ ΤΕΧΝΙΚΩΝ ΕΡΓΩΝ & ΥΠΟΔΟΜΩΝ',{align:AlignmentType.CENTER,size:20,after:0}));
body.push(P('ΤΜΗΜΑ ΠΡΟΜΗΘΕΙΩΝ',{align:AlignmentType.CENTER,size:20,after:240}));
body.push(RULE);
body.push(P('ΤΕΧΝΙΚΗ ΕΚΘΕΣΗ — ΤΕΧΝΙΚΕΣ ΠΡΟΔΙΑΓΡΑΦΕΣ',
  {bold:true,align:AlignmentType.CENTER,size:32,color:NAVY,after:60}));
body.push(P('«ΑΝΑΓΟΜΩΣΗ ΚΑΙ ΣΥΝΤΗΡΗΣΗ ΠΥΡΟΣΒΕΣΤΗΡΩΝ ΔΗΜΟΥ ΡΟΔΟΥ»',
  {bold:true,align:AlignmentType.CENTER,size:26,color:BLUE,after:60}));
body.push(P('Έτος 2026 · CPV: 24951230-6',{align:AlignmentType.CENTER,size:20,italics:true,after:120}));
body.push(P(`Ενδεικτικός προϋπολογισμός: ${eur(grand)} (συμπεριλαμβανομένου Φ.Π.Α. 24%)`,
  {align:AlignmentType.CENTER,bold:true,size:22,after:240}));
body.push(RULE);

// ───────────────────────── 1. ΑΝΤΙΚΕΙΜΕΝΟ ─────────────────────────
body.push(H('1. ΑΝΤΙΚΕΙΜΕΝΟ ΤΗΣ ΜΕΛΕΤΗΣ',HeadingLevel.HEADING_1));
body.push(P('Με την παρούσα μελέτη προβλέπεται ο έλεγχος, η συντήρηση, η αναγόμωση και η υδραυλική δοκιμή (επανέλεγχος) των φορητών και τροχήλατων πυροσβεστήρων όλων των τύπων, καθώς και των αυτόματων πυροσβεστήρων οροφής και των μονίμων συστημάτων τοπικής εφαρμογής ξηράς κόνεως, που είναι εγκατεστημένα στα κτίρια και τις εγκαταστάσεις του Δήμου Ρόδου.',{align:AlignmentType.JUSTIFIED}));
body.push(P(`Η μελέτη περιλαμβάνει είκοσι δύο (22) διακριτά είδη εργασιών, συνολικής ποσότητας ${items.reduce((s,i)=>s+i.qty,0)} τεμαχίων. Οι εργασίες εκτελούνται υποχρεωτικά σύμφωνα με τις τελευταίες ισχύουσες εθνικές προδιαγραφές και ιδίως την Κ.Υ.Α. 618/43/2005, όπως έχει τροποποιηθεί και ισχύει.`,{align:AlignmentType.JUSTIFIED}));

// ───────────────────────── 2. ΘΕΣΜΙΚΟ ΠΛΑΙΣΙΟ ─────────────────────────
body.push(H('2. ΙΣΧΥΟΝ ΘΕΣΜΙΚΟ ΠΛΑΙΣΙΟ ΚΑΙ ΠΡΟΤΥΠΑ',HeadingLevel.HEADING_1));
body.push(P('Το σύνολο των εργασιών εκτελείται σύμφωνα με:',{after:80}));
[
 ['Κ.Υ.Α. 618/43/2005 (Φ.Ε.Κ. Β΄ 52/20.01.2005)','«Προϋποθέσεις διάθεσης στην αγορά πυροσβεστήρων, διαδικασίες συντήρησης, επανελέγχου και αναγόμωσης» — βασικό κείμενο, με τα Παραρτήματα ΙΙΙ (συντήρηση), IV (αναγόμωση), V (υδραυλική δοκιμή/επανέλεγχος), VI και VII.'],
 ['Κ.Υ.Α. 17230/671/2005 (Φ.Ε.Κ. Β΄ 1218/01.09.2005)','Τροποποίηση και συμπλήρωση της ανωτέρω· καθορίζει μεταξύ άλλων τις πινακίδες και το μητρώο συντήρησης-αναγόμωσης των αυτομάτων συστημάτων ξηράς κόνεως τοπικής εφαρμογής.'],
 ['Κ.Υ.Α. 140424/2021 (Φ.Ε.Κ. Β΄ 6254/27.12.2021)','Νεότερη τροποποίηση της Κ.Υ.Α. 618/43/2005 (αντικατάσταση του άρθρου 2 — πρώτη διάθεση στην αγορά και σήμανση συμμόρφωσης). Είναι η πλέον πρόσφατη τροποποίηση του πλαισίου.'],
 ['Πυροσβεστική Διάταξη 15/2022 (Φ.Ε.Κ. Β΄ 5602/2022)','Μέτρα και μέσα πυροπροστασίας — επάρκεια, χωροθέτηση και διατήρηση σε ετοιμότητα των φορητών μέσων.'],
 ['ΕΛΟΤ ΕΝ 3 (σειρά, ιδίως ΕΝ 3-7)','Φορητοί πυροσβεστήρες — χαρακτηριστικά, απαιτήσεις επίδοσης και κατασβεστική ικανότητα.'],
 ['ΕΛΟΤ ΕΝ 1866 (σειρά, ΕΝ 1866-1)','Τροχήλατοι πυροσβεστήρες.'],
 ['ΕΛΟΤ ΕΝ 615','Κατασβεστικές σκόνες (ξηρά κόνις) — απαιτήσεις και δοκιμές.'],
 ['ΕΝ 1568 / ΕΝ ISO 5923','Αφρογόνα κατασβεστικά μέσα και διοξείδιο του άνθρακα αντιστοίχως.'],
 ['Οδηγία 2014/68/ΕΕ (Π.Δ. 91/2018) και ADR/ΤΠΕΔ','Εξοπλισμός υπό πίεση και περιοδικός επανέλεγχος φιαλών CO₂ και προωθητικού αερίου.'],
].forEach(([a,b])=>{
  body.push(new Paragraph({spacing:{after:80},indent:{left:340,hanging:340},alignment:AlignmentType.JUSTIFIED,
    children:[new TextRun({text:'▪  ',bold:true,color:BLUE,size:20,font:FONT}),
              new TextRun({text:a+' — ',bold:true,size:20,font:FONT}),
              new TextRun({text:b,size:20,font:FONT})]}));
});

// ───────────────────────── 3. ΑΝΑΔΟΧΟΣ ─────────────────────────
body.push(H('3. ΑΠΑΙΤΗΣΕΙΣ ΚΑΙ ΥΠΟΧΡΕΩΣΕΙΣ ΤΟΥ ΑΝΑΔΟΧΟΥ (ΣΥΝΤΗΡΗΤΗ)',HeadingLevel.HEADING_1));
body.push(H('3.1 Τυπικά προσόντα — επί ποινή αποκλεισμού',HeadingLevel.HEADING_2,{size:22}));
[
 'Να είναι ΑΝΑΓΝΩΡΙΣΜΕΝΗ ΕΤΑΙΡΕΙΑ κατά την έννοια της Κ.Υ.Α. 618/43/2005 και να προσκομίσει το εν ισχύι Πιστοποιητικό Έγκρισης Κανονισμού Λειτουργίας Αναγνωρισμένης Εταιρείας, εκδοθέν από διαπιστευμένο φορέα πιστοποίησης.',
 'Να διαθέτει άδεια λειτουργίας του συνεργείου/εργαστηρίου αναγόμωσης από την αρμόδια Υπηρεσία της οικείας Περιφέρειας.',
 'Οι εργασίες να εκτελούνται αποκλειστικά από ΑΡΜΟΔΙΟ ΑΤΟΜΟ πιστοποιημένο κατά την Κ.Υ.Α. 618/43/2005 και 17230/671/2005· να κατατεθεί αντίγραφο του πιστοποιητικού με το ονοματεπώνυμο και τον αριθμό μητρώου του.',
 'Να διαθέτει κατάλληλο και διακριβωμένο εξοπλισμό υδραυλικής δοκιμής, ζύγισης και πλήρωσης, με εν ισχύι πιστοποιητικά διακρίβωσης των οργάνων μέτρησης.',
 'Να διαθέτει ασφαλιστήριο συμβόλαιο αστικής ευθύνης έναντι τρίτων για τις εκτελούμενες εργασίες.',
].forEach(t=>body.push(new Paragraph({spacing:{after:70},indent:{left:340,hanging:340},alignment:AlignmentType.JUSTIFIED,
  children:[new TextRun({text:'▪  ',bold:true,color:BLUE,size:20,font:FONT}),new TextRun({text:t,size:20,font:FONT})]})));

body.push(H('3.2 Υλικά αναγόμωσης',HeadingLevel.HEADING_2,{size:22}));
[
 'Η ξηρά κόνις να είναι ΚΑΙΝΟΥΡΓΙΑ, τύπου ABC με περιεκτικότητα φωσφορικού αμμωνίου τουλάχιστον 40%, πιστοποιημένη κατά ΕΛΟΤ ΕΝ 615, συνοδευόμενη από πιστοποιητικό με αναγραφή παρτίδας και ημερομηνίας παραγωγής. ΑΠΑΓΟΡΕΥΕΤΑΙ ρητώς η επαναχρησιμοποίηση της παλαιάς κόνεως.',
 'Το διοξείδιο του άνθρακα να είναι καθαρότητας τουλάχιστον 99,5%, με δελτίο δεδομένων ασφαλείας.',
 'Το προωθητικό αέριο να είναι ξηρό άζωτο υψηλής καθαρότητας.',
 'Τα κατασβεστικά υγρά κατηγορίας F και τα αφρογόνα AFFF να είναι εγκεκριμένου τύπου, εντός ημερομηνίας λήξεως, με πιστοποιητικό και αναγραφή παρτίδας. Απαγορεύεται η ανάμιξη υγρών διαφορετικών κατασκευαστών.',
 'Όλα τα ανταλλακτικά (βαλβίδες, παρεμβύσματα, μανόμετρα, σωλήνες, ακροφύσια) να είναι γνήσια ή ισοδύναμα εγκεκριμένου τύπου, συμβατά με τον εκάστοτε πυροσβεστήρα.',
].forEach(t=>body.push(new Paragraph({spacing:{after:70},indent:{left:340,hanging:340},alignment:AlignmentType.JUSTIFIED,
  children:[new TextRun({text:'▪  ',bold:true,color:BLUE,size:20,font:FONT}),new TextRun({text:t,size:20,font:FONT})]})));

body.push(H('3.3 Παραλαβή — παράδοση',HeadingLevel.HEADING_2,{size:22}));
body.push(P('Η παραλαβή και η παράδοση των πυροσβεστήρων γίνεται με μεταφορικό μέσο, ευθύνη και δαπάνη του αναδόχου, από και προς τις εγκαταστάσεις του Δήμου, κατόπιν έγγραφης διατακτικής στην οποία αναγράφονται η ημερομηνία και η ποσότητα ανά κατηγορία. Ο χρόνος παραλαβής – παράδοσης ορίζεται σε πέντε (5) εργάσιμες ημέρες. Καθ’ όλη τη διάρκεια της εργασίας ο ανάδοχος υποχρεούται να τοποθετεί πυροσβεστήρα αντικατάστασης ίδιου τύπου και κατηγορίας, ώστε να μην απομένει ακάλυπτη θέση πυροπροστασίας.',{align:AlignmentType.JUSTIFIED}));

// ───────────────────────── 4. ΠΕΡΙΟΔΙΚΟΤΗΤΑ ─────────────────────────
body.push(H('4. ΥΠΟΧΡΕΩΤΙΚΗ ΠΕΡΙΟΔΙΚΟΤΗΤΑ ΕΡΓΑΣΙΩΝ',HeadingLevel.HEADING_1));
body.push(P('Οι κάτωθι χρόνοι είναι υποχρεωτικοί κατά την Κ.Υ.Α. 618/43/2005 (Παραρτήματα ΙΙΙ, IV και V), όπως ισχύει. Οι χρόνοι μετρώνται από το έτος κατασκευής του πυροσβεστήρα ή από την τελευταία αντίστοιχη εργασία.',{align:AlignmentType.JUSTIFIED}));
const pcols=[2560,1500,1760,1980,1838];
body.push(table(pcols,[
  new TableRow({tableHeader:true,children:[
    cell('ΤΥΠΟΣ ΠΥΡΟΣΒΕΣΤΗΡΑ',{w:pcols[0],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
    cell('ΣΥΝΤΗΡΗΣΗ',{w:pcols[1],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
    cell('ΑΝΑΓΟΜΩΣΗ',{w:pcols[2],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
    cell('ΥΔΡΑΥΛΙΚΗ ΔΟΚΙΜΗ',{w:pcols[3],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
    cell('ΑΠΟΣΥΡΣΗ',{w:pcols[4],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER})]}),
  ...[
   ['Ξηράς κόνεως — φορητοί','12 μήνες','5 έτη','10 έτη','20 έτη'],
   ['Ξηράς κόνεως — τροχήλατοι','12 μήνες','5 έτη','10 έτη','20 έτη'],
   ['Ξηράς κόνεως — οροφής / τοπικής εφαρμογής','12 μήνες','5 έτη','10 έτη','20 έτη'],
   ['Διοξειδίου του άνθρακα (CO₂)','12 μήνες (με ζύγιση)','10 έτη *','10 έτη (ADR/ΤΠΕΔ)','βάσει επανελέγχου φιάλης'],
   ['Αφρού AFFF / νερού','12 μήνες','5 έτη','10 έτη','20 έτη'],
   ['Υγρού χημικού — κατηγορίας F','12 μήνες','5 έτη','10 έτη','20 έτη'],
  ].map((r,i)=>new TableRow({children:r.map((v,j)=>cell(v,{w:pcols[j],
      fill:i%2?ALT:undefined,align:j?AlignmentType.CENTER:undefined,bold:j===0}))}))
]));
body.push(P('* Στους πυροσβεστήρες CO₂ η αναγόμωση γίνεται υποχρεωτικά στη δεκαετία, ταυτόχρονα με την υδραυλική δοκιμή της φιάλης. Ανεξαρτήτως αυτού, κατά τον ετήσιο έλεγχο ο πυροσβεστήρας ζυγίζεται και αναγομώνεται ΑΜΕΣΑ εφόσον η απώλεια μάζας υπερβαίνει το 10% της ονομαστικής γόμωσης.',{italics:true,size:18,align:AlignmentType.JUSTIFIED,before:80}));
body.push(P('Σε κάθε περίπτωση, ο πυροσβεστήρας αναγομώνεται ΑΜΕΣΑ μετά από οποιαδήποτε χρήση του, έστω και μερική, καθώς και όταν κατά τον έλεγχο διαπιστωθεί πτώση πίεσης, φθορά ή απώλεια κατασβεστικού υλικού.',{align:AlignmentType.JUSTIFIED}));

// ───────────────────────── 5. ΣΗΜΑΝΣΗ ─────────────────────────
body.push(H('5. ΣΗΜΑΝΣΗ — ΔΑΚΤΥΛΙΟΣ ΕΠΑΝΕΛΕΓΧΟΥ',HeadingLevel.HEADING_1));
body.push(P('Σε κάθε πυροσβεστήρα που ανοίγεται τοποθετείται στον λαιμό ΔΑΚΤΥΛΙΟΣ ΕΠΑΝΕΛΕΓΧΟΥ από σκληρό και άκαμπτο πλαστικό, ώστε να μην είναι δυνατόν να αφαιρεθεί χωρίς άνοιγμα του κλείστρου, με ΑΝΑΓΛΥΦΗ την ημερομηνία ανοίγματος. Το χρώμα του δακτυλίου καθορίζεται από το τελευταίο ψηφίο του έτους εργασίας:',{align:AlignmentType.JUSTIFIED}));
const rcols=[1200,3619,1200,3619];
const ring=[['0','Άσπρο','5','Μπλε'],['1','Κίτρινο','6','Μωβ'],['2','Πορτοκαλί','7','Γκρι'],
            ['3','Καφέ','8','Βυσσινί'],['4','Πράσινο','9','Μαύρο']];
body.push(table(rcols,[
  new TableRow({tableHeader:true,children:['ΨΗΦΙΟ','ΧΡΩΜΑ','ΨΗΦΙΟ','ΧΡΩΜΑ'].map((h,j)=>
    cell(h,{w:rcols[j],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}))}),
  ...ring.map((r,i)=>new TableRow({children:r.map((v,j)=>cell(v,{w:rcols[j],fill:i%2?ALT:undefined,
    align:AlignmentType.CENTER,bold:(j===1&&v==='Μωβ')}))}))
]));
body.push(P('Για τις εργασίες που θα εκτελεστούν εντός του έτους 2026 ο δακτύλιος είναι ΜΩΒ· εφόσον η σύμβαση επεκταθεί στο 2027, ΓΚΡΙ.',{bold:true,align:AlignmentType.JUSTIFIED,before:80}));
body.push(P('Επιπλέον, σε κάθε πυροσβεστήρα επικολλάται νέα ετικέτα συντήρησης/αναγόμωσης, στην οποία αναγράφονται υποχρεωτικά: η επωνυμία και ο αριθμός αδείας της αναγνωρισμένης εταιρείας, το ονοματεπώνυμο και ο αριθμός πιστοποίησης του αρμοδίου ατόμου, το είδος της εργασίας, η ημερομηνία εκτέλεσης και η ημερομηνία της επόμενης υποχρεωτικής ενέργειας.',{align:AlignmentType.JUSTIFIED}));

// ───────────────────────── 6. ΚΟΙΝΕΣ ΕΡΓΑΣΙΕΣ ─────────────────────────
body.push(H('6. ΚΟΙΝΕΣ ΕΡΓΑΣΙΕΣ ΑΝΑΓΟΜΩΣΗΣ ΞΗΡΑΣ ΚΟΝΕΩΣ',HeadingLevel.HEADING_1));
body.push(P('Για όλους τους πυροσβεστήρες ξηράς κόνεως η αναγόμωση συνίσταται υποχρεωτικώς στα εξής, κατά το Παράρτημα IV της Κ.Υ.Α. 618/43/2005:',{align:AlignmentType.JUSTIFIED}));
[
 'Πλήρης εκτόνωση και αποσυναρμολόγηση του πυροσβεστήρα.',
 'Άδειασμα της κόνεως, καθάρισμα και πρεσάρισμα του σώματος.',
 'Ενδελεχής εσωτερικός έλεγχος με ΦΩΤΙΣΤΙΚΟ ΚΑΘΕΤΗΡΑ ΚΑΙ ΚΑΘΡΕΦΤΗ για διάβρωση, κοιλώματα, εγκοπές, χτυπήματα ή ζημιά της εσωτερικής επιφάνειας — με ιδιαίτερη προσοχή στα σημεία συγκόλλησης.',
 'Συντήρηση ή αντικατάσταση της βαλβίδας του κλείστρου, των παρεμβυσμάτων (O-rings), του σωλήνα κατάθλιψης, του ακροφυσίου, του μανομέτρου και της περόνης ασφαλείας.',
 'Γέμισμα εκ νέου με κόνι ίδιου τύπου και ονομαστικής ποσότητας, πιστοποιημένη κατά ΕΛΟΤ ΕΝ 615.',
 'Πλήρωση με νέο αδρανές αέριο (άζωτο) στην ονομαστική πίεση λειτουργίας.',
 'Έλεγχος στεγανότητας και παρακολούθηση επί ένα τουλάχιστον 24ΩΡΟ για τυχόν απώλειες.',
 'Ζύγιση, τοποθέτηση δακτυλίου επανελέγχου, νέα ετικέτα και ενημέρωση του Μητρώου Συντήρησης & Αναγόμωσης.',
].forEach((t,i)=>body.push(new Paragraph({spacing:{after:70},indent:{left:400,hanging:400},alignment:AlignmentType.JUSTIFIED,
  children:[new TextRun({text:(i+1)+'.  ',bold:true,color:BLUE,size:20,font:FONT}),new TextRun({text:t,size:20,font:FONT})]})));

// ───────────────────────── 7. ΑΝΑ ΕΙΔΟΣ ─────────────────────────
body.push(new Paragraph({children:[new pkg.PageBreak()]}));
body.push(H('7. ΑΝΑΛΥΤΙΚΗ ΤΕΧΝΙΚΗ ΠΕΡΙΓΡΑΦΗ ΑΝΑ ΕΙΔΟΣ',HeadingLevel.HEADING_1));
body.push(P('Ακολουθεί, ένα προς ένα, το σύνολο των ειδών της μελέτης με τις απαιτήσεις που τίθενται στον συντηρητή.',{align:AlignmentType.JUSTIFIED}));

for (const it of items) {
  if (it.section) body.push(H(it.section,HeadingLevel.HEADING_2,{size:22,color:BLUE,before:300}));
  body.push(new Paragraph({spacing:{before:200,after:60},
    shading:{type:ShadingType.CLEAR,fill:LIGHT,color:'auto'},
    children:[new TextRun({text:`ΕΙΔΟΣ ${it.ordinal}.  ${it.name}`,bold:true,size:21,color:NAVY,font:FONT})]}));
  body.push(new Paragraph({spacing:{after:60},children:[
    new TextRun({text:'Ποσότητα: ',bold:true,size:19,font:FONT}),
    new TextRun({text:`${it.qty} ${it.unit}`,size:19,font:FONT}),
    new TextRun({text:'   ·   Τιμή μονάδας: ',bold:true,size:19,font:FONT}),
    new TextRun({text:eur(it.price),size:19,font:FONT}),
    new TextRun({text:'   ·   Δαπάνη: ',bold:true,size:19,font:FONT}),
    new TextRun({text:eur(it.qty*it.price),size:19,font:FONT}),
    new TextRun({text:'   ·   CPV: ',bold:true,size:19,font:FONT}),
    new TextRun({text:it.cpv,size:19,font:FONT})]}));
  body.push(new Paragraph({spacing:{after:60},alignment:AlignmentType.JUSTIFIED,children:[
    new TextRun({text:'Πρότυπα / νομοθεσία: ',bold:true,size:18,font:FONT}),
    new TextRun({text:it.standards,size:18,italics:true,font:FONT})]}));
  body.push(new Paragraph({spacing:{after:60},alignment:AlignmentType.JUSTIFIED,children:[
    new TextRun({text:'Απαιτούμενες εργασίες: ',bold:true,size:19,font:FONT}),
    new TextRun({text:it.specs,size:19,font:FONT})]}));
  body.push(new Paragraph({spacing:{after:120},alignment:AlignmentType.JUSTIFIED,
    border:{left:{style:BorderStyle.SINGLE,size:12,color:BLUE,space:6}},
    indent:{left:160},children:[
    new TextRun({text:'Υποχρεωτική περιοδικότητα: ',bold:true,size:18,color:NAVY,font:FONT}),
    new TextRun({text:it.notes,size:18,font:FONT})]}));
}

// ───────────────────────── 8. ΠΡΟΫΠΟΛΟΓΙΣΜΟΣ ─────────────────────────
body.push(new Paragraph({children:[new pkg.PageBreak()]}));
body.push(H('8. ΕΝΔΕΙΚΤΙΚΟΣ ΠΡΟΫΠΟΛΟΓΙΣΜΟΣ',HeadingLevel.HEADING_1));
const bcols=[560,4560,760,860,1140,1758];
const brows=[new TableRow({tableHeader:true,children:[
  cell('Α/Α',{w:bcols[0],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
  cell('ΠΕΡΙΓΡΑΦΗ',{w:bcols[1],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
  cell('Μ.Μ.',{w:bcols[2],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
  cell('ΠΟΣΟΤ.',{w:bcols[3],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
  cell('ΤΙΜΗ ΜΟΝ.',{w:bcols[4],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER}),
  cell('ΔΑΠΑΝΗ',{w:bcols[5],fill:BLUE,bold:true,color:'FFFFFF',align:AlignmentType.CENTER})]})];
items.forEach((it,i)=>brows.push(new TableRow({children:[
  cell(it.ordinal,{w:bcols[0],align:AlignmentType.CENTER,fill:i%2?ALT:undefined,size:17}),
  cell(it.name,{w:bcols[1],fill:i%2?ALT:undefined,size:17}),
  cell(it.unit,{w:bcols[2],align:AlignmentType.CENTER,fill:i%2?ALT:undefined,size:17}),
  cell(it.qty,{w:bcols[3],align:AlignmentType.CENTER,fill:i%2?ALT:undefined,size:17}),
  cell(eur(it.price),{w:bcols[4],align:AlignmentType.RIGHT,fill:i%2?ALT:undefined,size:17}),
  cell(eur(it.qty*it.price),{w:bcols[5],align:AlignmentType.RIGHT,fill:i%2?ALT:undefined,size:17})]})));
const sumRow=(label,value,bold)=>new TableRow({children:[
  new TableCell({width:{size:bcols[0]+bcols[1]+bcols[2]+bcols[3]+bcols[4],type:WidthType.DXA},
    columnSpan:5,shading:{type:ShadingType.CLEAR,fill:LIGHT,color:'auto'},
    margins:{top:60,bottom:60,left:80,right:80},
    children:[new Paragraph({alignment:AlignmentType.RIGHT,spacing:{after:0},
      children:[new TextRun({text:label,bold:true,size:18,color:NAVY,font:FONT})]})]}),
  cell(value,{w:bcols[5],align:AlignmentType.RIGHT,fill:LIGHT,bold:true,size:18,color:NAVY})]});
brows.push(sumRow('ΣΥΝΟΛΟ (άνευ Φ.Π.Α.)',eur(total)));
brows.push(sumRow('Φ.Π.Α. 24%',eur(vat)));
brows.push(sumRow('ΓΕΝΙΚΟ ΣΥΝΟΛΟ (με Φ.Π.Α. 24%)',eur(grand)));
body.push(table(bcols,brows));

// ───────────────────────── 9. ΠΑΡΑΛΑΒΗ ─────────────────────────
body.push(H('9. ΠΟΙΟΤΙΚΟΣ ΕΛΕΓΧΟΣ, ΠΑΡΑΔΟΤΕΑ ΚΑΙ ΠΑΡΑΛΑΒΗ',HeadingLevel.HEADING_1));
body.push(P('Με την ολοκλήρωση κάθε παρτίδας εργασιών ο ανάδοχος παραδίδει στην Υπηρεσία:',{after:80}));
[
 'ΜΗΤΡΩΟ ΣΥΝΤΗΡΗΣΗΣ ΚΑΙ ΑΝΑΓΟΜΩΣΗΣ ανά πυροσβεστήρα, με τον αύξοντα αριθμό/σειριακό, τον τύπο, το έτος κατασκευής, το είδος της εργασίας, την ημερομηνία εκτέλεσης και την ημερομηνία της επόμενης υποχρεωτικής ενέργειας.',
 'ΠΙΣΤΟΠΟΙΗΤΙΚΑ ΥΔΡΑΥΛΙΚΗΣ ΔΟΚΙΜΗΣ για όσα δοχεία υποβλήθηκαν σε επανέλεγχο δεκαετίας, με αναφορά της πίεσης δοκιμής και του αποτελέσματος.',
 'ΠΙΣΤΟΠΟΙΗΤΙΚΑ ΥΛΙΚΩΝ (κόνις κατά ΕΛΟΤ ΕΝ 615, CO₂, αφρογόνο, υγρό κατηγορίας F) με αναγραφή παρτίδας.',
 'ΒΕΒΑΙΩΣΗ ΚΑΛΗΣ ΛΕΙΤΟΥΡΓΙΑΣ για τα μόνιμα συστήματα τοπικής εφαρμογής και τους αυτόματους πυροσβεστήρες οροφής.',
 'ΕΓΓΡΑΦΗ ΓΝΩΣΤΟΠΟΙΗΣΗ των πυροσβεστήρων που κρίθηκαν ακατάλληλοι ή συμπλήρωσαν εικοσαετία και πρέπει να αποσυρθούν, με τεκμηρίωση της καταστροφής τους.',
].forEach(t=>body.push(new Paragraph({spacing:{after:70},indent:{left:340,hanging:340},alignment:AlignmentType.JUSTIFIED,
  children:[new TextRun({text:'▪  ',bold:true,color:BLUE,size:20,font:FONT}),new TextRun({text:t,size:20,font:FONT})]})));
body.push(P('Η Υπηρεσία διατηρεί το δικαίωμα δειγματοληπτικού ελέγχου οποιουδήποτε πυροσβεστήρα (ζύγιση, έλεγχος πίεσης, έλεγχος σήμανσης και δακτυλίου). Σε περίπτωση διαπίστωσης πλημμελούς εργασίας, ο ανάδοχος υποχρεούται σε άμεση επανάληψή της χωρίς πρόσθετη αποζημίωση, επιφυλασσομένων των ποινικών ρητρών του άρθρου 218 του Ν. 4412/2016.',{align:AlignmentType.JUSTIFIED}));
body.push(P('Οι εργασίες εκτελούνται σύμφωνα με τις τελευταίες Εθνικές Προδιαγραφές. Τα υλικά και οι εργασίες υπόκεινται στα Ευρωπαϊκά πρότυπα πιστοποίησης. Η δαπάνη βαρύνει τον Κ.Α. 10-6261.0002 «Αναγόμωση πυροσβεστήρων Δήμου Ρόδου».',{align:AlignmentType.JUSTIFIED}));

body.push(new Paragraph({spacing:{before:600},alignment:AlignmentType.CENTER,children:[
  new TextRun({text:'Ρόδος,  ……… / ……… / 2026',size:20,font:FONT})]}));
body.push(new Paragraph({spacing:{before:400},alignment:AlignmentType.CENTER,children:[
  new TextRun({text:'Ο ΣΥΝΤΑΞΑΣ',bold:true,size:20,font:FONT})]}));
body.push(new Paragraph({spacing:{before:700},alignment:AlignmentType.CENTER,children:[
  new TextRun({text:'ΘΕΩΡΗΘΗΚΕ  —  Ο ΠΡΟΪΣΤΑΜΕΝΟΣ',bold:true,size:20,font:FONT})]}));

const doc = new Document({
  creator:'Δήμος Ρόδου', title:'Τεχνική Έκθεση — Αναγόμωση & Συντήρηση Πυροσβεστήρων 2026',
  styles:{default:{document:{run:{font:FONT,size:20}}}},
  sections:[{
    properties:{page:{margin:{top:1134,right:1134,bottom:1134,left:1134}}},
    footers:{default:new Footer({children:[new Paragraph({alignment:AlignmentType.CENTER,
      children:[new TextRun({text:'Δήμος Ρόδου — Αναγόμωση & Συντήρηση Πυροσβεστήρων 2026 · Σελίδα ',size:16,font:FONT}),
                new TextRun({children:[PageNumber.CURRENT],size:16,font:FONT}),
                new TextRun({text:' από ',size:16,font:FONT}),
                new TextRun({children:[PageNumber.TOTAL_PAGES],size:16,font:FONT})]})]})},
    children:body
  }]
});
const buf = await Packer.toBuffer(doc);
const { writeFileSync } = await import('fs');
writeFileSync('ΤΕΧΝΙΚΗ_ΕΚΘΕΣΗ_ΠΥΡΟΣΒΕΣΤΗΡΕΣ_ΡΟΔΟΥ_2026.docx', buf);
console.log('OK — παράχθηκε το .docx, μέγεθος', buf.length, 'bytes');
