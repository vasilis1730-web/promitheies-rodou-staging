begin;

-- v36.5.5 hotfix — Διάκριση της Δ.Ε. Νότιας Ρόδου από τη Δ.Ε. Ρόδου.
-- Η πραγματική εγγραφή του εγκατεστημένου καταλόγου είναι στη γενική
-- «ΝΟΤΙΑΣ ΡΟΔΟΥ». Ο προηγούμενος κανόνας αναγνώριζε μόνο την ονομαστική
-- «ΝΟΤΙΑ ΡΟΔΟΣ», με αποτέλεσμα να καταλήγει στον γενικό κανόνα «ΡΟΔΟΥ»
-- και να εντάσσει λανθασμένα τη Νότια Ρόδο στην Ομάδα 1.
-- Δεν μετονομάζεται και δεν μεταβάλλεται καμία Δημοτική Ενότητα.

do $$
declare
  v_version text;
begin
  if to_regprocedure('public.app_schema_version()') is null
     or to_regprocedure('public.app_greek_key(text)') is null
     or to_regprocedure('public.app_rhodes_municipal_unit_code(text,text)') is null
     or to_regprocedure('public.app_rhodes_award_group_no(text,text)') is null
     or to_regprocedure('public.app_rhodes_award_group_template()') is null then
    raise exception 'Λείπουν οι απαιτούμενες συναρτήσεις της v36.5.5.';
  end if;

  select public.app_schema_version() into v_version;
  if v_version <> '36.5.5' then
    raise exception 'Το hotfix ομάδων απαιτεί schema 36.5.5, βρέθηκε %.', v_version;
  end if;
end;
$$;

create or replace function public.app_rhodes_municipal_unit_code(
  p_name text,
  p_short_name text
)
returns text
language plpgsql
immutable
parallel safe
as $$
declare
  v_key text := public.app_greek_key(coalesce(p_name, '') || ' ' || coalesce(p_short_name, ''));
begin
  -- Οι δύο πτώσεις ελέγχονται πρώτες, πριν από τον γενικό κανόνα «ΡΟΔΟΥ».
  if position('νοτιαροδο' in v_key) > 0
     or position('νοτιασροδο' in v_key) > 0 then
    return 'south_rhodes';
  end if;
  if position('ιαλυσο' in v_key) > 0 then return 'ialysos'; end if;
  if position('καλλιθε' in v_key) > 0 then return 'kallithea'; end if;
  if position('αφαντ' in v_key) > 0 then return 'afantou'; end if;
  if position('λινδ' in v_key) > 0 then return 'lindos'; end if;
  if position('αρχαγγελ' in v_key) > 0 then return 'archangelos'; end if;
  if position('πεταλουδ' in v_key) > 0 then return 'petaloudes'; end if;
  if position('καμειρ' in v_key) > 0 then return 'kamiros'; end if;
  if position('αταβυρ' in v_key) > 0
     or position('ατταβυρ' in v_key) > 0 then
    return 'attavyros';
  end if;
  if position('ροδο' in v_key) > 0 then return 'rhodes'; end if;
  return null;
end;
$$;

revoke all on function public.app_rhodes_municipal_unit_code(text,text) from public, anon;

do $$
declare
  v_template_units integer;
  v_distinct_codes integer;
  v_group_1 integer;
  v_group_2 integer;
  v_group_3 integer;
  v_group_4 integer;
begin
  if public.app_rhodes_municipal_unit_code(
       'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', 'ΝΟΤΙΑΣ ΡΟΔΟΥ'
     ) is distinct from 'south_rhodes'
     or public.app_rhodes_award_group_no(
       'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', 'ΝΟΤΙΑΣ ΡΟΔΟΥ'
     ) is distinct from 3 then
    raise exception 'Απέτυχε η αναγνώριση της πραγματικής εγγραφής της Δ.Ε. Νότιας Ρόδου στην Ομάδα 3.';
  end if;

  if public.app_rhodes_municipal_unit_code(
       'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', 'ΡΟΔΟΥ'
     ) is distinct from 'rhodes'
     or public.app_rhodes_award_group_no(
       'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', 'ΡΟΔΟΥ'
     ) is distinct from 1 then
    raise exception 'Απέτυχε η διατήρηση της Δ.Ε. Ρόδου στην Ομάδα 1.';
  end if;

  if public.app_rhodes_municipal_unit_code(
       'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΑΒΥΡΟΥ'
     ) is distinct from 'attavyros'
     or public.app_rhodes_municipal_unit_code(
       'Αττάβυρος', 'Ατταβύρου'
     ) is distinct from 'attavyros' then
    raise exception 'Το hotfix δεν διατήρησε τη διπλή γραφή της Δ.Ε. Αταβύρου.';
  end if;

  select
    count(*),
    count(distinct public.app_rhodes_municipal_unit_code(u.name, u.short_name))
  into v_template_units, v_distinct_codes
  from public.municipal_units u
  where u.id::bigint <> 11;

  select
    count(*) filter (where t.group_no = 1),
    count(*) filter (where t.group_no = 2),
    count(*) filter (where t.group_no = 3),
    count(*) filter (where t.group_no = 4)
  into v_group_1, v_group_2, v_group_3, v_group_4
  from public.app_rhodes_award_group_template() t;

  if v_template_units <> 10
     or v_distinct_codes <> 10
     or v_group_1 <> 1
     or v_group_2 <> 3
     or v_group_3 <> 3
     or v_group_4 <> 3 then
    raise exception 'Η σταθερή κατανομή πρέπει να είναι 1/3/3/3 σε 10 διακριτές Δ.Ε., βρέθηκε %/%/%/% σε % εγγραφές και % κωδικούς.',
      v_group_1, v_group_2, v_group_3, v_group_4, v_template_units, v_distinct_codes;
  end if;

  if exists (
    select 1
    from public.award_group_configurations c
    where c.is_active
      and not public.app_award_group_configuration_is_canonical(c.budget_year)
      and exists (
        select 1
        from public.locked_studies s
        join public.award_groups g on g.id = s.award_group_id
        where g.configuration_id = c.id
          and s.record_status = 'active'
      )
  ) then
    raise exception 'Υπάρχει ενεργή μη κανονική κατανομή με κλειδωμένες μελέτες. Απαιτείται ελεγχόμενη διόρθωση πριν από το hotfix.';
  end if;
end;
$$;

comment on function public.app_rhodes_municipal_unit_code(text,text) is
  'Κανονικοποιεί τις 10 Δ.Ε. Ρόδου· διακρίνει τη ΝΟΤΙΑΣ ΡΟΔΟΥ από τη ΡΟΔΟΥ και δέχεται ΑΤΑΒΥΡΟΥ/ΑΤΤΑΒΥΡΟΥ.';

commit;
