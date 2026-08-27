# -*- coding: utf-8 -*-
import sys, json, re
sys.path.insert(0,'.')
import items as SRV
import supplies as SUP

FRAG = {
 '@PRE':  SRV.PRE,   '@POST': SRV.POST,  '@DRY': SRV.DRY_CORE,
 '@BODY': SUP.BODY,  '@CE':   SUP.CE,    '@LABEL': SUP.LABEL, '@NEW': SUP.NEW,
}
# Οι μεγαλύτερες πρώτα, ώστε να μη «φάει» μια μικρή ένα κομμάτι μεγαλύτερης.
ORDER = sorted(FRAG, key=lambda k: -len(FRAG[k]))

def templatize(text):
    out = text
    for k in ORDER:
        out = out.replace(FRAG[k], k)
    return out

def expand(tpl):
    out = tpl
    for k in ORDER:
        out = out.replace(k, FRAG[k])
    return out

SUBCAT_SRV = {1:'Φορητοί πυροσβεστήρες ξηράς κόνεως',5:'Τροχήλατοι πυροσβεστήρες ξηράς κόνεως',
 7:'Πυροσβεστήρες διοξειδίου του άνθρακα (CO₂)',11:'Αυτόματοι οροφής & συστήματα τοπικής εφαρμογής',
 14:'Περιοδική συντήρηση πενταετίας',16:'Πυροσβεστήρες κατηγορίας F & αφρού AFFF',
 20:'Υδραυλική δοκιμή (επανέλεγχος δεκαετίας)',22:'Λοιπές εργασίες μονίμων συστημάτων'}
def subcat_srv(aa):
    cur=None
    for k in sorted(SUBCAT_SRV):
        if aa>=k: cur=SUBCAT_SRV[k]
    return cur

def q(s):
    return "'" + str(s).replace("'","''") + "'"

# ── επαλήθευση ανασύνθεσης ─────────────────────────────────────────────────
bad=0
srv_rows=[]
for aa,name,qty,price,std,sec,specs,notes in SRV.ITEMS:
    tpl=templatize(specs)
    if expand(tpl)!=specs:
        print('MISMATCH srv',aa); bad+=1
    srv_rows.append((aa,name,subcat_srv(aa),price,std,tpl,notes))
sup_rows=[]
for aa,name,price,std,sub,specs,notes in SUP.ITEMS:
    tpl=templatize(specs)
    if expand(tpl)!=specs:
        print('MISMATCH sup',aa); bad+=1
    sup_rows.append((aa,name,sub,price,std,tpl,notes))
if bad: sys.exit('ΑΠΟΤΥΧΙΑ ανασύνθεσης σε %d είδη'%bad)

raw = sum(len(i[6]) for i in SRV.ITEMS)+sum(len(i[5]) for i in SUP.ITEMS)
tpl = sum(len(r[5]) for r in srv_rows)+sum(len(r[5]) for r in sup_rows)
print('✅ ανασύνθεση ταυτόσημη για %d είδη' % (len(srv_rows)+len(sup_rows)))
print('   κείμενο προδιαγραφών: %d χαρ. → %d χαρ. με placeholders (-%d%%)' % (raw,tpl,round(100-100*tpl/raw)))

frag_sql = ",\n  ".join("%s AS %s" % (q(FRAG[k]), k[1:].lower()) for k in ['@PRE','@POST','@DRY','@BODY','@CE','@LABEL','@NEW'])

def repl(col):
    e=col
    for k in ORDER:
        e = "replace(%s,%s,f.%s)" % (e, q(k), k[1:].lower())
    return e

# ── 1) UPDATE ομάδας 29 (υπηρεσίες) ────────────────────────────────────────
vals = ",\n  ".join("(%d,%s,%s,%s,%s,%s,%s)"%(r[0],q(r[1]),q(r[2]),repr(float(r[3])),q(r[4]),q(r[5]),q(r[6])) for r in srv_rows)
sql1 = """WITH f AS (SELECT
  %s
), v(so,name,subcat,price,std,tpl,notes) AS (VALUES
  %s
)
UPDATE materials m SET
  name=v.name, short_name=v.name, subcategory=v.subcat,
  unit='τεμ.', quantity_scale=0, cpv='24951230-6',
  technical_specs=%s,
  standards=v.std, notes_for_tender=v.notes,
  default_unit_price=v.price, ce_required=false, is_active=true
FROM v, f
WHERE m.group_id=29 AND m.sort_order=v.so;""" % (frag_sql, vals, repl('v.tpl'))

# ── 2) INSERT ομάδας προμηθειών + ειδών ────────────────────────────────────
vals2 = ",\n  ".join("(%d,%s,%s,%s,%s,%s,%s)"%(r[0],q(r[1]),q(r[2]),repr(float(r[3])),q(r[4]),q(r[5]),q(r[6])) for r in sup_rows)
sql2 = """WITH f AS (SELECT
  %s
), g AS (
  INSERT INTO procurement_groups (code,name,short_name,sort_order,domain,is_active)
  VALUES ('fire_extinguishers','ΠΥΡΟΣΒΕΣΤΗΡΕΣ','Πυροσβεστήρες',15,'procurement',true)
  RETURNING id
), v(so,name,subcat,price,std,tpl,notes) AS (VALUES
  %s
)
INSERT INTO materials
  (group_id,code,name,short_name,subcategory,unit,quantity_scale,cpv,
   technical_specs,standards,ce_required,notes_for_tender,default_unit_price,is_active,sort_order)
SELECT g.id, 'FIR-2026-'||lpad(v.so::text,3,'0'), v.name, v.name, v.subcat, 'τεμ.', 0, '%s',
       %s, v.std, true, v.notes, v.price, true, v.so
FROM g, v, f;""" % (frag_sql, vals2, SUP.CPV, repl('v.tpl'))

open('sql1_services.sql','w',encoding='utf-8').write(sql1)
open('sql2_supplies.sql','w',encoding='utf-8').write(sql2)
print('   sql1: %d bytes · sql2: %d bytes' % (len(sql1),len(sql2)))
