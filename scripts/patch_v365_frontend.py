from pathlib import Path
import re, hashlib, base64, json

p=Path('index.html')
s=p.read_text(encoding='utf-8')

# 1. Aggregate contract query must expose actual/estimated pricing metadata.
old='sb.from("mo_contracts").select("id,source_study_id,supplier_id,adam,protocol_no,start_date,end_date,total_amount").eq("municipal_unit_id",unitId)'
new='sb.from("mo_contracts").select("id,source_study_id,supplier_id,adam,protocol_no,start_date,end_date,total_amount,estimated_amount,pricing_mode,discount_pct,vat_rate").eq("municipal_unit_id",unitId)'
if s.count(old)!=1: raise SystemExit(f'loadUnitAgg selector count={s.count(old)}')
s=s.replace(old,new)

# 2. In study cards, once a contract exists the operational ceiling is the actual contract amount.
start=s.index('function renderStudies(content){')
end=s.index('async function openStudy(stdy){',start)
block=s[start:end]
old='const total=num(stdy.net_total);'
new='const total=con?num(con.total_amount):num(stdy.net_total);'
if block.count(old)!=1: raise SystemExit(f'renderStudies total count={block.count(old)}')
block=block.replace(old,new)
old='el("span",{},"Καθαρή αξία: ",el("b",{},eur(total)))'
new='el("span",{},con?"Συμβατική αξία: ":"Εκτιμώμενη αξία: ",el("b",{},eur(total)))'
if block.count(old)!=1: raise SystemExit(f'renderStudies label count={block.count(old)}')
block=block.replace(old,new)
s=s[:start]+block+s[end:]

# 3. Assignment explanatory copy.
old='"Για την έκδοση δελτίων καταχωρίστε πρώτα την ανάθεση της μελέτης: "+(dm==="service"?"ανάδοχο":"προμηθευτή")+", στοιχεία επικοινωνίας και ΑΔΑΜ. Το τιμολόγιο ειδών εισάγεται αυτόματα από τη μελέτη ("+((stdy.lines||[]).length)+" είδη).")'
new='"Για την έκδοση δελτίων καταχωρίστε πρώτα την ανάθεση: "+(dm==="service"?"ανάδοχο":"προμηθευτή")+", ΑΔΑΜ/διάρκεια και την πραγματική οικονομική προσφορά. Η εκτιμώμενη αξία της μελέτης παραμένει χωριστή από τις κατακυρωμένες τιμές ("+((stdy.lines||[]).length)+" είδη).")'
if s.count(old)!=1: raise SystemExit(f'assignment copy count={s.count(old)}')
s=s.replace(old,new)

# 4. Replace assignment form with contract-pricing-aware form.
start=s.index('function assignForm(existing){')
end=s.index('\n/* ---------- φόρμα δελτίου ---------- */',start)
new_form=r'''function contractPricingModeLabel(c){
  const m=(c&&c.pricing_mode)||"study";
  if(m==="discount")return "Ενιαία έκπτωση "+qy(c.discount_pct||0)+"%";
  if(m==="item_prices")return "Κατακυρωμένες τιμές ανά είδος";
  return "Τιμές μελέτης";
}
function contractPricingRows(stdy,existing){
  const src=existing?(st.citems||[]):(stdy.lines||[]);
  return src.map((x,i)=>({
    key:String(x.id||x.material_id||i),
    contract_item_id:existing?x.id:null,
    material_id:x.material_id||null,
    code:x.code||"",
    description:x.description||x.name||x.short_name||"—",
    unit:x.unit||"",
    quantity:num(x.contract_qty!=null?x.contract_qty:x.quantity),
    estimated_price:num(x.estimated_unit_price!=null?x.estimated_unit_price:x.unit_price),
    actual_price:num(x.unit_price)
  }));
}
function assignForm(existing){
  const stdy=st.study,dm=domainOf(stdy);
  const isNew=!existing;
  const c=existing?Object.assign({},existing):{supplier_id:"",adam:"",protocol_no:"",
    start_date:todayISO(),end_date:stdy.request_year+"-12-31",vat_rate:num(S.vat)||24,
    pricing_mode:"study",discount_pct:0};
  const f={};
  const supSel=el("select",{});
  function fillSup(selId){
    supSel.innerHTML="";
    supSel.append(el("option",{value:""},"— Επιλογή "+(dm==="service"?"αναδόχου":"προμηθευτή")+" —"));
    st.suppliers.filter(x=>x.active!==false).forEach(x=>supSel.append(el("option",{value:x.id,selected:sameId(selId||c.supplier_id,x.id)?"":null},x.name)));
  }
  fillSup();
  const grName=(stdy.procurement_groups||{}).name||"";
  const autoTitle=(dm==="service"?"Παροχή υπηρεσιών: ":"Προμήθεια: ")+grName+" — "+unitName(st.unitId)+" "+stdy.request_year+" (Μελέτη Νο"+(stdy.seq||1)+")";
  const rows=contractPricingRows(stdy,existing);
  const modeSel=el("select",{disabled:existing?"":null},
    el("option",{value:"study",selected:(c.pricing_mode||"study")==="study"?"":null},"Ίδιες τιμές με τη μελέτη"),
    el("option",{value:"discount",selected:c.pricing_mode==="discount"?"":null},"Ενιαία έκπτωση %"),
    el("option",{value:"item_prices",selected:c.pricing_mode==="item_prices"?"":null},"Πραγματική τιμή ανά είδος"));
  const discountInp=el("input",{type:"number",min:"0",max:"99.9999",step:"0.0001",value:c.discount_pct||0,disabled:existing?"":null});
  const itemBody=el("tbody",{});
  const priceInputs=new Map();
  rows.forEach((r,i)=>{
    const inp=el("input",{type:"number",min:"0",step:"0.0001",value:r.actual_price||r.estimated_price,disabled:existing?"":null,style:"width:110px"});
    priceInputs.set(r.key,inp);
    itemBody.append(el("tr",{},
      el("td",{},String(i+1)),
      el("td",{},(r.code?r.code+" — ":"")+r.description),
      el("td",{},r.unit||"—"),
      el("td",{style:"text-align:right"},qy(r.quantity)),
      el("td",{style:"text-align:right"},eur(r.estimated_price)),
      el("td",{style:"text-align:right"},inp)));
  });
  const itemBox=el("div",{style:"overflow:auto;max-height:280px;border:1px solid var(--line);border-radius:8px"},
    el("table",{class:"data",style:"width:100%;font-size:12px"},
      el("thead",{},el("tr",{},el("th",{},"Α/Α"),el("th",{},"Είδος / εργασία"),el("th",{},"Μον."),el("th",{},"Ποσ."),el("th",{},"Τιμή μελέτης"),el("th",{},"Συμβατική τιμή"))),itemBody));
  const itemSection=el("div",{},itemBox);
  const discountSection=el("div",{class:"mo-field"},el("label",{},"Ενιαία έκπτωση %"),discountInp);
  const preview=el("div",{class:"mo-card mo-pad",style:"margin:10px 0;background:#F8FBFE"});
  const pricingHelp=el("p",{class:"mo-muted",style:"font-size:12px;margin:6px 0 0"},
    existing?"Οι κατακυρωμένες τιμές της υφιστάμενης σύμβασης είναι αμετάβλητες. Εδώ επιτρέπεται μόνο διορθωτική ενημέρωση διοικητικών στοιχείων.":
    "Η εκτιμώμενη αξία παραμένει αυτή της κλειδωμένης μελέτης και συνεχίζει να προσμετράται στο όριο των 30.000 €. Η πραγματική συμβατική αξία προκύπτει από την οικονομική προσφορά.");
  function pricingTotal(){
    const mode=modeSel.value;
    const disc=Math.max(0,Math.min(99.9999,num(discountInp.value)));
    return Math.round(rows.reduce((sum,r)=>{
      let pr=r.estimated_price;
      if(mode==="discount")pr=r.estimated_price*(100-disc)/100;
      else if(mode==="item_prices")pr=num((priceInputs.get(r.key)||{}).value);
      return sum+r.quantity*pr;
    },0)*100)/100;
  }
  function updatePricingUI(){
    const mode=modeSel.value;
    discountSection.style.display=mode==="discount"?"":"none";
    itemSection.style.display=mode==="item_prices"?"":"none";
    const estimated=num(stdy.net_total),actual=pricingTotal(),saving=Math.round((estimated-actual)*100)/100;
    preview.innerHTML="";
    preview.append(
      el("div",{class:"mo-study-fig"},
        el("span",{},"Εκτιμώμενη καθαρή αξία: ",el("b",{},eur(estimated))),
        el("span",{},"Συμβατική καθαρή αξία: ",el("b",{style:actual>estimated+0.005?"color:var(--mo-err)":"color:var(--mo-ok)"},eur(actual))),
        el("span",{},"Διαφορά: ",el("b",{},eur(saving)))),
      el("div",{class:"mo-muted",style:"font-size:11.5px;margin-top:5px"},"Τρόπος: "+(mode==="study"?"τιμές μελέτης":mode==="discount"?("ενιαία έκπτωση "+qy(discountInp.value)+"%"):"πραγματικές τιμές ανά είδος")));
  }
  modeSel.addEventListener("change",updatePricingUI);
  discountInp.addEventListener("input",updatePricingUI);
  priceInputs.forEach(inp=>inp.addEventListener("input",updatePricingUI));
  const vatField=fld("ΦΠΑ %","vat_rate","number",c.vat_rate!=null?c.vat_rate:(num(S.vat)||24),f);
  f.vat_rate.step="0.01";f.vat_rate.min="0";f.vat_rate.max="100";if(existing)f.vat_rate.disabled=true;
  const body=el("div",{},
    el("p",{class:"mo-muted",style:"margin-top:0"},el("b",{},studyTitle(stdy)),
      " · Εκτιμώμενη καθαρή αξία: ",el("b",{},eur(stdy.net_total)),
      stdy.supplier_name?(" · Προμηθευτής μελέτης: "+stdy.supplier_name):""),
    el("div",{class:"mo-field"},el("label",{},LBL().partyLbl+" *"),
      el("div",{style:"display:flex;gap:8px;align-items:center"},supSel,
        el("button",{class:"mo-btn mo-sm",type:"button",onclick:()=>supplierForm(null,ns=>{fillSup(ns.id);supSel.value=ns.id;},stdy.supplier_name||"")},"＋ Νέος"))),
    row2(fld("ΑΔΑΜ","adam","text",c.adam,f,"π.χ. 26SYMV000000000"),fld("Αρ. πρωτοκόλλου","protocol_no","text",c.protocol_no,f)),
    row2(fld("Έναρξη","start_date","date",c.start_date,f),fld("Λήξη","end_date","date",c.end_date,f)),
    vatField,
    el("div",{class:"mo-field"},el("label",{},"Οικονομική προσφορά / συμβατικές τιμές"),modeSel),
    discountSection,itemSection,preview,pricingHelp);
  updatePricingUI();
  openModal(isNew?"Καταχώριση ανάθεσης":"Επεξεργασία ανάθεσης",body,[
    {label:"Άκυρο",cls:"mo-btn",act:closeModal},
    {label:"Αποθήκευση",cls:"mo-btn mo-primary",act:async()=>{
      const supplier_id=supSel.value;
      if(!supplier_id){T("Επιλέξτε "+(dm==="service"?"ανάδοχο":"προμηθευτή")+".","warn");return;}
      const data={supplier_id,adam:(val(f,"adam",c.adam)||"").trim()||null,
        protocol_no:(val(f,"protocol_no",c.protocol_no)||"").trim()||null,
        start_date:val(f,"start_date",c.start_date)||null,end_date:val(f,"end_date",c.end_date)||null,
        vat_rate:num(val(f,"vat_rate",c.vat_rate!=null?c.vat_rate:24))};
      if(data.vat_rate<0||data.vat_rate>100){T("Ο ΦΠΑ πρέπει να είναι από 0% έως 100%.","warn");return;}
      try{
        let error=null;
        if(isNew){
          const mode=modeSel.value,discount=num(discountInp.value);
          const actual=pricingTotal();
          if(actual>num(stdy.net_total)+0.005){T("Η συμβατική αξία δεν μπορεί να υπερβαίνει την εκτιμώμενη αξία της μελέτης.","warn");return;}
          let itemPrices=null;
          if(mode==="item_prices"){
            itemPrices=rows.map(r=>({material_id:String(r.material_id||""),unit_price:num((priceInputs.get(r.key)||{}).value)}));
            if(itemPrices.some(x=>!x.material_id||x.unit_price<0)){T("Συμπληρώστε έγκυρη συμβατική τιμή για κάθε είδος.","warn");return;}
          }
          ({error}=await sb.rpc('save_contract_pricing_atomic',{
            p_contract_id:null,p_study_id:String(stdy.id),p_supplier_id:String(supplier_id),p_title:autoTitle,
            p_adam:data.adam,p_protocol_no:data.protocol_no,p_start_date:data.start_date,p_end_date:data.end_date,
            p_vat_rate:data.vat_rate,p_pricing_mode:mode,p_discount_pct:mode==="discount"?discount:0,p_item_prices:itemPrices
          }));
        }else{
          ({error}=await sb.rpc('save_contract_atomic',{
            p_contract_id:String(existing.id),p_study_id:String(stdy.id),p_supplier_id:String(supplier_id),p_title:autoTitle,
            p_adam:data.adam,p_protocol_no:data.protocol_no,p_start_date:data.start_date,p_end_date:data.end_date,p_vat_rate:num(existing.vat_rate)
          }));
        }
        if(error)throw error;
        closeModal();T(isNew?"Η ανάθεση και οι κατακυρωμένες τιμές αποθηκεύτηκαν.":"Τα διοικητικά στοιχεία της ανάθεσης ενημερώθηκαν.","ok");
        await openStudy(stdy);
      }catch(e){T("Σφάλμα: "+(e.message||e),"err");}
    }}],true);
}
'''
s=s[:start]+new_form+s[end:]

# 5. New order VAT always starts from the actual contract, never a browser-only preference.
old='vat_rate:num(S.vat)||24,status:"draft",created_by:ME.id,'
new='vat_rate:num(st.contract&&st.contract.vat_rate!=null?st.contract.vat_rate:S.vat)||24,status:"draft",created_by:ME.id,'
if s.count(old)!=1: raise SystemExit(f'blankForm VAT count={s.count(old)}')
s=s.replace(old,new)

# 6. Contract summary: show estimate, actual award and pricing mode.
needle='(st.contract.adam?("ΑΔΑΜ "+st.contract.adam+" · "):"")+(st.contract.protocol_no?(st.contract.protocol_no+" · "):"")+\n        dGR(st.contract.start_date)+"–"+dGR(st.contract.end_date)))));'
repl='(st.contract.adam?("ΑΔΑΜ "+st.contract.adam+" · "):"")+(st.contract.protocol_no?(st.contract.protocol_no+" · "):"")+\n        dGR(st.contract.start_date)+"–"+dGR(st.contract.end_date)),\n      el("div",{class:"mo-muted",style:"font-size:12.5px"},\n        "Εκτιμώμενη: "+eur(st.contract.estimated_amount!=null?st.contract.estimated_amount:stdy.net_total)+" · Συμβατική: "+eur(st.contract.total_amount)+" · "+contractPricingModeLabel(st.contract)))));'
if s.count(needle)!=1: raise SystemExit(f'contract summary count={s.count(needle)}')
s=s.replace(needle,repl)

# 7. Version labels / schema gate.
s=s.replace('v36.6.4 PHASE 2 INTEGRITY','v36.6.5 CONTRACT PRICING')
s=s.replace('v36.6.4-phase2-integrity','v36.6.5-contract-pricing')
s=s.replace("REQUIRED_SCHEMA_VERSION='36.6.4'","REQUIRED_SCHEMA_VERSION='36.6.5'")
s=s.replace('REQUIRED_SCHEMA_VERSION="36.6.4"','REQUIRED_SCHEMA_VERSION="36.6.5"')

# 8. Recalculate CSP hashes for every inline script.
inline=[m.group(1) for m in re.finditer(r'<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)</script>',s,re.I)]
if len(inline)!=2: raise SystemExit(f'expected 2 inline scripts, got {len(inline)}')
hashes=["'sha256-"+base64.b64encode(hashlib.sha256(x.encode()).digest()).decode()+"'" for x in inline]
def repl_csp(m):
    c=m.group(1)
    c=re.sub(r"script-src [^;]+", "script-src 'self' file: "+' '.join(hashes), c, count=1)
    return '<meta http-equiv="Content-Security-Policy" content="'+c+'"'
s,n=re.subn(r'<meta\s+http-equiv="Content-Security-Policy"\s+content="([^"]+)"',repl_csp,s,count=1,flags=re.I)
if n!=1: raise SystemExit('CSP meta not found')
p.write_text(s,encoding='utf-8')

# 9. Package version.
pp=Path('package.json'); pkg=json.loads(pp.read_text()); pkg['version']='36.6.5'; pp.write_text(json.dumps(pkg,ensure_ascii=False,indent=2)+'\n')
pl=Path('package-lock.json'); lock=json.loads(pl.read_text()); lock['version']='36.6.5';
if isinstance(lock.get('packages'),dict) and '' in lock['packages']: lock['packages']['']['version']='36.6.5'
pl.write_text(json.dumps(lock,ensure_ascii=False,indent=2)+'\n')
