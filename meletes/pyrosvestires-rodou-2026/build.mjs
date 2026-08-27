import ExcelJS from 'exceljs';
import { readFileSync } from 'fs';

const items = JSON.parse(readFileSync('items.json','utf8'));
const VAT = 0.24;
const colors={navy:'FF1F4E79',blue:'FF2E75B6',section:'FFDDEBF7',alt:'FFF2F7FC',
  white:'FFFFFFFF',border:'FFBFBFBF',text:'FF000000',muted:'FF595959'};
const thin={style:'thin',color:{argb:colors.border}};
const border={top:thin,left:thin,bottom:thin,right:thin};

const wb = new ExcelJS.Workbook();
await wb.xlsx.readFile('../template.xlsx');
const ws = wb.getWorksheet('Συντήρηση πυροσβεστήρων');

// 1) Ξεμερδεύουμε τα merges των γραμμών δεδομένων (7..38) — τα merged section rows
//    σπάνε τον έλεγχο εισαγωγής της εφαρμογής (το κείμενο "χύνεται" σε Α/Α και CE).
for (const range of [...(ws.model.merges||[])]) {
  const top = parseInt(range.match(/[A-Z]+(\d+)/)[1],10);
  if (top >= 7) ws.unMergeCells(range);
}
// 2) Καθαρίζουμε ρητά κάθε κελί των παλιών γραμμών δεδομένων (7 έως το τέλος).
//    Το spliceRows() του ExcelJS αφήνει έωλα κελιά, γι' αυτό μηδενίζουμε ένα-ένα.
const oldLast = ws.rowCount;
for (let rr = 7; rr <= oldLast; rr++) {
  const row = ws.getRow(rr);
  for (let c = 1; c <= 12; c++) {
    const cell = row.getCell(c);
    cell.value = null;
    cell.style = {};
    cell.dataValidation = undefined;
    cell.note = undefined;
  }
  row.height = undefined;
}

// 3) Γράφουμε τα νέα είδη.
let r = 7, currentSection = null, visible = 0;
for (const it of items) {
  if (it.section && it.section !== currentSection) {
    currentSection = it.section;
    const row = ws.getRow(r);
    // ΣΗΜΑΝΤΙΚΟ: ο τίτλος ενότητας μπαίνει ΜΟΝΟ στη στήλη Β (ΠΕΡΙΓΡΑΦΗ) και ξεκινά
    // με «ΟΜΑΔΑ », ώστε η εισαγωγή της εφαρμογής να τον προσπερνά (χωρίς merge).
    row.getCell(2).value = currentSection;
    for (let c=1;c<=12;c++){
      const cell=row.getCell(c);
      cell.fill={type:'pattern',pattern:'solid',fgColor:{argb:colors.section}};
      cell.font={name:'Arial',size:10,bold:true,color:{argb:colors.navy}};
      cell.border=border;
      cell.alignment={horizontal:'left',vertical:'middle'};
    }
    row.height=20; r++;
  }
  visible++;
  const row = ws.getRow(r);
  row.values=[it.ordinal,it.name,it.unit,it.cpv,it.standards,it.price,it.qty,null,null,it.specs,it.ce,it.notes];
  row.height=18;
  const fillColor=(visible%2===0)?colors.alt:colors.white;
  row.eachCell({includeEmpty:true},cell=>{
    cell.fill={type:'pattern',pattern:'solid',fgColor:{argb:fillColor}};
    cell.font={name:'Arial',size:9,color:{argb:colors.text}};
    cell.border=border;cell.alignment={vertical:'middle',wrapText:false};
  });
  row.getCell(1).alignment={horizontal:'center',vertical:'middle'};
  row.getCell(2).alignment={horizontal:'left',vertical:'middle',wrapText:true};
  row.getCell(3).alignment={horizontal:'center',vertical:'middle'};
  row.getCell(4).alignment={horizontal:'center',vertical:'middle'};
  row.getCell(5).alignment={horizontal:'left',vertical:'middle',wrapText:true};
  row.getCell(10).alignment={horizontal:'left',vertical:'middle'};
  [6,7,8,9].forEach(c=>row.getCell(c).alignment={horizontal:'right',vertical:'middle'});
  row.getCell(6).numFmt='#,##0.00 "€"';
  row.getCell(7).numFmt='0';
  row.getCell(7).dataValidation={type:'whole',operator:'greaterThanOrEqual',showErrorMessage:true,
    errorTitle:'Μη έγκυρη ποσότητα',error:'Επιτρέπονται μόνο ακέραιες, μη αρνητικές ποσότητες.',formulae:[0]};
  row.getCell(8).value={formula:`IF(OR(F${r}="",G${r}=""),"",F${r}*G${r})`,result:it.price*it.qty};
  row.getCell(8).numFmt='#,##0.00 "€"';
  row.getCell(9).value={formula:`IF(F${r}="","",F${r}*(1+'ΣΗΜΕΙΩΣΕΙΣ'!$B$2))`,result:it.price*(1+VAT)};
  row.getCell(9).numFmt='#,##0.00 "€"';
  r++;
}

// 4) Αφαιρούμε τυχόν πλεονάζουσες γραμμές κάτω από τα δεδομένα.
if (ws.rowCount >= r) ws.spliceRows(r, ws.rowCount - r + 1);

ws.autoFilter={from:{row:6,column:1},to:{row:6,column:9}};
await wb.xlsx.writeFile('ΠΥΡΟΣΒΕΣΤΗΡΕΣ_ΡΟΔΟΥ_2026.xlsx');
console.log('γράφτηκαν', items.length, 'είδη · τελευταία γραμμή', r-1);
