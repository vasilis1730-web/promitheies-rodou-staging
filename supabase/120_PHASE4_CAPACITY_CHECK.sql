-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΦΑΣΗ 4: ΕΛΕΓΧΟΣ ΧΩΡΗΤΙΚΟΤΗΤΑΣ ΟΜΑΔΩΝ Δ.Ε.
--
-- Εκτελείται στο ΠΑΛΙΟ ΠΑΡΑΓΩΓΙΚΟ, πριν από τη μεταφορά δεδομένων.
-- READ-ONLY: δεν δημιουργεί, δεν μεταβάλλει και δεν διαγράφει τίποτα.
-- Δεν απαιτεί κανένα αντικείμενο της v36.3+ (award_groups, RPC, record_status).
--
-- Απαντά στο ερώτημα: αν οι υπάρχουσες κλειδωμένες μελέτες ενταχθούν στην
-- τετράδα ομάδων, ξεπερνά κάποια ομάδα το κοινό όριο των 30.000 € ανά
-- ομοειδές αντικείμενο;
--
-- ΔΙΑΦΟΡΑ ΑΠΟ ΤΟ ΕΡΩΤΗΜΑ ΤΗΣ §4.4 ΤΟΥ ΒΗΜΑ4:
-- Ο κανόνας «upper(name) like '%ΡΟΔΟΥ%'» της §4.4 έχει δύο σφάλματα που
-- διογκώνουν αποκλειστικά την Ομάδα 1:
--   1. Η «ΝΟΤΙΑΣ ΡΟΔΟΥ» περιέχει τη λέξη «ΡΟΔΟΥ» και προσμετράται ΚΑΙ στην
--      Ομάδα 1 ΚΑΙ στην Ομάδα 3 — οι μελέτες της μετρώνται δύο φορές.
--   2. Ο «ΔΗΜΟΣ ΡΟΔΟΥ» (κεντρική μονάδα, id 11) προσμετράται στην Ομάδα 1,
--      ενώ η εφαρμογή τον εξαιρεί ρητά από την κατανομή (CENTRAL_UNIT).
-- Το παρόν ερώτημα αναπαράγει πιστά τον κανόνα της εφαρμογής
-- (canonicalAwardUnitCodeForUnit στο index.html) και επιστρέφει και τα δύο
-- αποτελέσματα, ώστε η διαφορά να είναι ορατή.
-- ============================================================================

-- --------------------------------------------------------------------------
-- 0. Προϋποθέσεις. Σταματά με σαφές μήνυμα αντί για λανθασμένους αριθμούς.
-- --------------------------------------------------------------------------
do $$
declare
  missing text;
begin
  select string_agg(t, ', ') into missing from (
    select 'public.municipal_units' as t where to_regclass('public.municipal_units') is null
    union all select 'public.locked_studies' where to_regclass('public.locked_studies') is null
    union all select 'public.procurement_groups' where to_regclass('public.procurement_groups') is null
  ) x;
  if missing is not null then
    raise exception 'ΦΑΣΗ 4 — λείπουν απαιτούμενοι πίνακες: %', missing;
  end if;

  select string_agg(t, ', ') into missing from (
    select 'municipal_units.name' as t where not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='municipal_units' and column_name='name')
    union all select 'locked_studies.municipal_unit_id' where not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='locked_studies' and column_name='municipal_unit_id')
    union all select 'locked_studies.group_id' where not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='locked_studies' and column_name='group_id')
    union all select 'locked_studies.net_total' where not exists (
      select 1 from information_schema.columns
      where table_schema='public' and table_name='locked_studies' and column_name='net_total')
  ) x;
  if missing is not null then
    raise exception 'ΦΑΣΗ 4 — λείπουν απαιτούμενες στήλες: %. Το ερώτημα σταματά αντί να επιστρέψει λανθασμένα σύνολα.', missing;
  end if;
end $$;

-- --------------------------------------------------------------------------
-- 1. Ενιαία αναφορά χωρητικότητας.
-- --------------------------------------------------------------------------
with
params as (
  -- Το κοινό καθαρό όριο ανά ομοειδές αντικείμενο και η κεντρική μονάδα που
  -- εξαιρείται από την κατανομή (CENTRAL_UNIT στο index.html).
  select 30000::numeric as cap, 11::bigint as central_unit_id
),
unit_key as (
  -- Αναπαραγωγή του norm() της εφαρμογής: πεζά, χωρίς τόνους, μόνο γράμματα.
  select
    u.id,
    u.name,
    regexp_replace(
      translate(
        lower(coalesce(u.name, '') || ' ' || coalesce(u.short_name, '')),
        'άέήίόύώϊϋΐΰ',
        'αεηιουωιυιυ'
      ),
      '[^a-z0-9α-ω]', '', 'g'
    ) as key
  from public.municipal_units u
),
unit_code as (
  -- Η σειρά των κανόνων είναι σημαντική: η «ΝΟΤΙΑΣ ΡΟΔΟΥ» αναγνωρίζεται
  -- ΠΡΙΝ από τον γενικό κανόνα «ΡΟΔΟΥ», όπως ακριβώς στην εφαρμογή.
  select
    k.id, k.name, k.key,
    case
      when k.key ~ 'νοτια[σς]?ροδο' then 'south_rhodes'
      when k.key like '%ιαλυσο%'    then 'ialysos'
      when k.key like '%καλλιθε%'   then 'kallithea'
      when k.key like '%αφαντ%'     then 'afantou'
      when k.key like '%λινδ%'      then 'lindos'
      when k.key like '%αρχαγγελ%'  then 'archangelos'
      when k.key like '%πεταλουδ%'  then 'petaloudes'
      when k.key like '%καμειρ%'    then 'kamiros'
      when k.key ~ 'ατ{1,2}αβυρ'    then 'attavyros'
      when k.key like '%ροδο%'      then 'rhodes'
      else null
    end as code
  from unit_key k
),
unit_group as (
  select
    c.id, c.name, c.code,
    case
      when c.code = 'rhodes' then 1
      when c.code in ('ialysos', 'kallithea', 'afantou') then 2
      when c.code in ('lindos', 'south_rhodes', 'archangelos') then 3
      when c.code in ('petaloudes', 'kamiros', 'attavyros') then 4
    end as group_no
  from unit_code c, params p
  where c.id <> p.central_unit_id
),
group_names(group_no, onomasia) as (
  values
    (1, 'Ρόδου'),
    (2, 'Ιαλυσού – Καλλιθέας – Αφάντου'),
    (3, 'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου'),
    (4, 'Πεταλουδών – Καμείρου – Ατταβύρου')
),
-- Ο κανόνας της §4.4, αυτούσιος, μόνο για σύγκριση.
legacy_rule(group_no, monades) as (
  values
    (1, array['ΡΟΔΟΥ']),
    (2, array['ΙΑΛΥΣ', 'ΚΑΛΛΙΘΕ', 'ΑΦΑΝΤ']),
    (3, array['ΛΙΝΔ', 'ΝΟΤΙΑ', 'ΑΡΧΑΓΓΕΛ']),
    (4, array['ΠΕΤΑΛΟΥΔ', 'ΚΑΜΕΙΡ', 'ΑΤΑΒΥΡ'])
),
legacy_map as (
  select u.id, l.group_no
  from public.municipal_units u
  join legacy_rule l on exists (
    select 1 from unnest(l.monades) pattern where upper(u.name) like '%' || pattern || '%'
  )
),
per_group as (
  select
    ug.group_no,
    g.code as category_code,
    g.name as category_name,
    count(*) as studies,
    sum(s.net_total)::numeric as total
  from unit_group ug
  join public.locked_studies s on s.municipal_unit_id = ug.id
  join public.procurement_groups g on g.id = s.group_id
  where ug.group_no is not null
  group by ug.group_no, g.code, g.name
),
legacy_per_group as (
  select
    lm.group_no,
    g.code as category_code,
    sum(s.net_total)::numeric as total
  from legacy_map lm
  join public.locked_studies s on s.municipal_unit_id = lm.id
  join public.procurement_groups g on g.id = s.group_id
  group by lm.group_no, g.code
)
select jsonb_pretty(jsonb_build_object(
  'elegxos', 'ΦΑΣΗ 4 — χωρητικότητα ομάδων Δ.Ε.',
  'orio_eur', (select cap from params),

  -- Α. Ακεραιότητα αντιστοίχισης. Πρέπει: 10 Δ.Ε., καμία αγνώριστη.
  'antistoixisi', jsonb_build_object(
    'entotites_pou_katanemithikan', (select count(*) from unit_group where group_no is not null),
    'kentriki_monada_pou_exairethike', (
      select jsonb_build_object('id', u.id, 'name', u.name)
      from public.municipal_units u, params p where u.id = p.central_unit_id
    ),
    'agnoristes_entotites', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by id)
      from unit_group where group_no is null
    ), '[]'::jsonb),
    'ana_omada', (
      select jsonb_agg(jsonb_build_object(
        'omada', gn.group_no,
        'onomasia', gn.onomasia,
        'enotites', coalesce((
          select jsonb_agg(ug.name order by ug.name)
          from unit_group ug where ug.group_no = gn.group_no
        ), '[]'::jsonb)
      ) order by gn.group_no)
      from group_names gn
    )
  ),

  -- Β. Χωρητικότητα ανά ομάδα και ομοειδές αντικείμενο.
  'xoritikotita', coalesce((
    select jsonb_agg(jsonb_build_object(
      'omada', pg.group_no,
      'onomasia', gn.onomasia,
      'katigoria', pg.category_name,
      'kodikos', pg.category_code,
      'meletes', pg.studies,
      'synolo_eur', round(pg.total, 2),
      'ypoloipo_eur', round((select cap from params) - pg.total, 2),
      'katastasi', case when pg.total > (select cap from params) then 'ΥΠΕΡΒΑΣΗ' else 'εντός' end
    ) order by pg.group_no, pg.category_code)
    from per_group pg join group_names gn on gn.group_no = pg.group_no
  ), '[]'::jsonb),

  -- Γ. Διαφορά από τον κανόνα της §4.4, για να μη μοιάζει με ασυμφωνία.
  'diafora_apo_kanona_4_4', coalesce((
    select jsonb_agg(jsonb_build_object(
      'omada', l.group_no,
      'kodikos', l.category_code,
      'synolo_kanona_4_4_eur', round(l.total, 2),
      'synolo_diorthomeno_eur', round(coalesce(p.total, 0), 2),
      'diafora_eur', round(l.total - coalesce(p.total, 0), 2)
    ) order by l.group_no, l.category_code)
    from legacy_per_group l
    left join per_group p on p.group_no = l.group_no and p.category_code = l.category_code
    where l.total is distinct from coalesce(p.total, 0)
  ), '[]'::jsonb),

  -- Δ. Ετυμηγορία.
  'etymigoria', case
    when exists (select 1 from unit_group where group_no is null)
      then 'ΣΤΟΠ — υπάρχουν Δημοτικές Ενότητες που δεν αναγνωρίζονται. Η κατανομή δεν μπορεί να οριστεί.'
    when (select count(*) from unit_group where group_no is not null) <> 10
      then 'ΣΤΟΠ — δεν προέκυψαν ακριβώς 10 Δημοτικές Ενότητες.'
    when exists (select 1 from per_group where total > (select cap from params))
      then 'ΥΠΕΡΒΑΣΗ — απαιτείται διοικητική απόφαση πριν τη μεταφορά. Δες το πεδίο xoritikotita.'
    else 'ΕΝΤΟΣ ΟΡΙΩΝ — η μεταφορά μπορεί να προχωρήσει στη Φάση 5.'
  end
)) as anafora;
