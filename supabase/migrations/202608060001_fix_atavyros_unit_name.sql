begin;

-- v36.5.5 hotfix — Αναγνώριση της Δ.Ε. Αταβύρου και με τις δύο γραφές.
-- Η εγκατεστημένη εγγραφή είναι «ΑΤΑΒΥΡΟΥ» (ένα τ), ενώ η ονομασία της
-- σταθερής Ομάδας 4 χρησιμοποιεί «Ατταβύρου» (δύο τ).
-- Δεν μετονομάζεται και δεν μεταβάλλεται καμία Δημοτική Ενότητα.

do $$
declare
  v_version text;
begin
  if to_regprocedure('public.app_schema_version()') is null
     or to_regprocedure('public.app_rhodes_municipal_unit_code(text,text)') is null then
    raise exception 'Λείπουν οι απαιτούμενες συναρτήσεις της v36.5.5.';
  end if;

  select public.app_schema_version() into v_version;
  if v_version <> '36.5.5' then
    raise exception 'Το hotfix Αταβύρου απαιτεί schema 36.5.5, βρέθηκε %.', v_version;
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
  if position('νοτιαροδο' in v_key) > 0 then return 'south_rhodes'; end if;
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
  v_template_groups integer;
begin
  if public.app_rhodes_municipal_unit_code(
       'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΑΒΥΡΟΥ'
     ) is distinct from 'attavyros'
     or public.app_rhodes_municipal_unit_code(
       'Αττάβυρος', 'Ατταβύρου'
     ) is distinct from 'attavyros' then
    raise exception 'Απέτυχε η αναγνώριση των δύο γραφών της Δ.Ε. Αταβύρου.';
  end if;

  select count(*), count(distinct group_no)
  into v_template_units, v_template_groups
  from public.app_rhodes_award_group_template();

  if v_template_units <> 10 or v_template_groups <> 4 then
    raise exception 'Η σταθερή κατανομή πρέπει να επιστρέφει 10 Δ.Ε. και 4 ομάδες, βρέθηκαν % και %.',
      v_template_units, v_template_groups;
  end if;
end;
$$;

comment on function public.app_rhodes_municipal_unit_code(text,text) is
  'Κανονικοποιεί τις 10 Δ.Ε. Ρόδου· δέχεται ΑΤΑΒΥΡΟΥ και ΑΤΤΑΒΥΡΟΥ ως την ίδια Δ.Ε.';

commit;
