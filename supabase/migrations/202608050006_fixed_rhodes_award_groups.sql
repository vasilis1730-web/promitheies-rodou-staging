begin;

-- v36.5.1 — Σταθερή κατανομή των δέκα Δημοτικών Ενοτήτων του Δήμου Ρόδου.
-- Το καθαρό όριο των 30.000 ευρώ εφαρμόζεται ανά οικονομικό έτος,
-- ανά ομάδα Δ.Ε. και ανά ομοειδή ομάδα προμήθειας ή υπηρεσίας.

create or replace function public.app_greek_key(p_value text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(
    translate(
      lower(coalesce(p_value, '')),
      'άέήίϊΐόύϋΰώς',
      'αεηιιιουυυωσ'
    ),
    '[^a-z0-9α-ω]+', '', 'g'
  )
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
  -- Η αρχική βάση έχει «ΑΤΑΒΥΡΟΥ», ενώ χρησιμοποιείται και «ΑΤΤΑΒΥΡΟΥ».
  if position('αταβυρ' in v_key) > 0
     or position('ατταβυρ' in v_key) > 0 then
    return 'attavyros';
  end if;
  if position('ροδο' in v_key) > 0 then return 'rhodes'; end if;
  return null;
end;
$$;

create or replace function public.app_rhodes_award_group_no(
  p_name text,
  p_short_name text
)
returns smallint
language plpgsql
immutable
parallel safe
as $$
declare
  v_code text := public.app_rhodes_municipal_unit_code(p_name, p_short_name);
begin
  return case
    when v_code = 'rhodes' then 1
    when v_code in ('ialysos','kallithea','afantou') then 2
    when v_code in ('lindos','south_rhodes','archangelos') then 3
    when v_code in ('petaloudes','kamiros','attavyros') then 4
    else null
  end;
end;
$$;

create or replace function public.app_rhodes_award_group_no(p_municipal_unit_id bigint)
returns smallint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.app_rhodes_award_group_no(u.name, u.short_name)
  from public.municipal_units u
  where u.id::bigint = p_municipal_unit_id
    and u.id::bigint <> 11
$$;

create or replace function public.app_rhodes_award_group_name(p_group_no integer)
returns text
language sql
immutable
parallel safe
as $$
  select case p_group_no
    when 1 then 'Ρόδου'
    when 2 then 'Ιαλυσού – Καλλιθέας – Αφάντου'
    when 3 then 'Λίνδου – Νότιας Ρόδου – Αρχαγγέλου'
    when 4 then 'Πεταλουδών – Καμείρου – Ατταβύρου'
    else null
  end
$$;

create or replace function public.app_rhodes_award_group_template()
returns table (
  group_no smallint,
  group_name text,
  municipal_unit_id bigint,
  municipal_unit_name text
)
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select
    public.app_rhodes_award_group_no(u.id::bigint),
    public.app_rhodes_award_group_name(public.app_rhodes_award_group_no(u.id::bigint)),
    u.id::bigint,
    coalesce(nullif(btrim(u.short_name), ''), u.name)
  from public.municipal_units u
  where u.id::bigint <> 11
  order by public.app_rhodes_award_group_no(u.id::bigint), u.sort_order, u.id
$$;

create or replace function public.app_award_group_configuration_is_canonical(p_budget_year integer)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_configuration_id bigint;
begin
  if (select count(*) from public.municipal_units u where u.id::bigint <> 11) <> 10
     or (select count(distinct public.app_rhodes_municipal_unit_code(u.name,u.short_name)) from public.municipal_units u where u.id::bigint <> 11) <> 10 then
    return false;
  end if;

  select c.id
  into v_configuration_id
  from public.award_group_configurations c
  where c.budget_year = p_budget_year
    and c.is_active
    and c.direct_award_cap = 30000.00;

  if v_configuration_id is null then return false; end if;

  if (select count(*) from public.award_groups g where g.configuration_id = v_configuration_id) <> 4 then
    return false;
  end if;

  if exists (
    select 1
    from public.award_groups g
    where g.configuration_id = v_configuration_id
      and (
        g.group_no not between 1 and 4
        or g.name <> public.app_rhodes_award_group_name(g.group_no)
      )
  ) then return false; end if;

  if exists (
    select 1
    from public.municipal_units u
    where u.id::bigint <> 11
      and public.app_rhodes_award_group_no(u.id::bigint) is null
  ) then return false; end if;

  if exists (
    select 1
    from public.municipal_units u
    where u.id::bigint <> 11
      and not exists (
        select 1
        from public.award_group_memberships m
        join public.award_groups g
          on g.id = m.award_group_id
         and g.configuration_id = m.configuration_id
        where m.configuration_id = v_configuration_id
          and m.municipal_unit_id::bigint = u.id::bigint
          and g.group_no = public.app_rhodes_award_group_no(u.id::bigint)
      )
  ) then return false; end if;

  if exists (
    select 1
    from public.award_group_memberships m
    join public.award_groups g
      on g.id = m.award_group_id
     and g.configuration_id = m.configuration_id
    left join public.municipal_units u on u.id = m.municipal_unit_id
    where m.configuration_id = v_configuration_id
      and (
        u.id is null
        or u.id::bigint = 11
        or public.app_rhodes_award_group_no(u.id::bigint) is distinct from g.group_no
      )
  ) then return false; end if;

  return true;
end;
$$;

create or replace function public.enforce_fixed_rhodes_award_cap()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if (select count(*) from public.municipal_units u where u.id::bigint <> 11) <> 10
     or (select count(distinct public.app_rhodes_municipal_unit_code(u.name,u.short_name)) from public.municipal_units u where u.id::bigint <> 11) <> 10
     or exists (
       select 1
       from public.municipal_units u
       where u.id::bigint <> 11
         and public.app_rhodes_award_group_no(u.id::bigint) is null
     ) then
    raise exception 'Ο κατάλογος πρέπει να περιλαμβάνει και να αναγνωρίζει ακριβώς τις 10 Δημοτικές Ενότητες του Δήμου Ρόδου.';
  end if;
  if new.direct_award_cap is distinct from 30000.00::numeric then
    raise exception 'Το καθαρό όριο απευθείας ανάθεσης είναι σταθερό: 30.000,00 € ανά ομάδα Δ.Ε., έτος και ομοειδές αντικείμενο.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fixed_rhodes_award_cap on public.award_group_configurations;
create trigger trg_fixed_rhodes_award_cap
before insert or update of direct_award_cap on public.award_group_configurations
for each row execute function public.enforce_fixed_rhodes_award_cap();

create or replace function public.enforce_fixed_rhodes_award_group()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_expected_name text;
begin
  v_expected_name := public.app_rhodes_award_group_name(new.group_no);
  if v_expected_name is null or new.name is distinct from v_expected_name then
    raise exception 'Η ομάδα % πρέπει να έχει την ενσωματωμένη ονομασία «%».', new.group_no, coalesce(v_expected_name, 'μη έγκυρη ομάδα');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fixed_rhodes_award_group on public.award_groups;
create trigger trg_fixed_rhodes_award_group
before insert or update of group_no, name on public.award_groups
for each row execute function public.enforce_fixed_rhodes_award_group();

create or replace function public.enforce_fixed_rhodes_award_membership()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_actual_group_no smallint;
  v_expected_group_no smallint;
begin
  select g.group_no into v_actual_group_no
  from public.award_groups g
  where g.id = new.award_group_id
    and g.configuration_id = new.configuration_id;

  v_expected_group_no := public.app_rhodes_award_group_no(new.municipal_unit_id::bigint);
  if v_expected_group_no is null then
    raise exception 'Η Δημοτική Ενότητα % δεν αναγνωρίζεται στην ενσωματωμένη κατανομή του Δήμου Ρόδου.', new.municipal_unit_id;
  end if;
  if v_actual_group_no is distinct from v_expected_group_no then
    raise exception 'Η Δημοτική Ενότητα % ανήκει υποχρεωτικά στην ομάδα % και όχι στην ομάδα %.',
      new.municipal_unit_id, v_expected_group_no, coalesce(v_actual_group_no, 0);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_fixed_rhodes_award_membership on public.award_group_memberships;
create trigger trg_fixed_rhodes_award_membership
before insert or update of configuration_id, award_group_id, municipal_unit_id
on public.award_group_memberships
for each row execute function public.enforce_fixed_rhodes_award_membership();

create or replace function public.enforce_canonical_group_on_locked_study()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_group_no smallint;
  v_configuration_year integer;
  v_cap numeric(14,2);
  v_active boolean;
  v_expected_group_no smallint;
begin
  select g.group_no, c.budget_year, c.direct_award_cap, c.is_active
  into v_group_no, v_configuration_year, v_cap, v_active
  from public.award_groups g
  join public.award_group_configurations c on c.id = g.configuration_id
  where g.id = new.award_group_id;

  v_expected_group_no := public.app_rhodes_award_group_no(new.municipal_unit_id::bigint);
  if v_expected_group_no is null
     or v_group_no is distinct from v_expected_group_no
     or v_configuration_year is distinct from new.request_year
     or v_cap is distinct from 30000.00::numeric
     or not coalesce(v_active, false)
     or not public.app_award_group_configuration_is_canonical(new.request_year) then
    raise exception 'Το κλείδωμα αποκλείεται: η ενεργή κατανομή δεν συμφωνεί με τις τέσσερις ενσωματωμένες ομάδες Δ.Ε. και το όριο των 30.000,00 €.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_canonical_group_on_locked_study on public.locked_studies;
create trigger trg_canonical_group_on_locked_study
before insert or update of award_group_id, municipal_unit_id, request_year
on public.locked_studies
for each row execute function public.enforce_canonical_group_on_locked_study();

create or replace function public.app_schema_version()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select '36.5.1'::text
$$;

revoke all on function public.app_greek_key(text) from public, anon;
revoke all on function public.app_rhodes_municipal_unit_code(text,text) from public, anon;
revoke all on function public.app_rhodes_award_group_no(text,text) from public, anon;
revoke all on function public.app_rhodes_award_group_no(bigint) from public, anon;
revoke all on function public.app_rhodes_award_group_name(integer) from public, anon;
revoke all on function public.app_rhodes_award_group_template() from public, anon;
revoke all on function public.app_award_group_configuration_is_canonical(integer) from public, anon;
revoke all on function public.app_schema_version() from public, anon;

grant execute on function public.app_rhodes_award_group_template() to authenticated;
grant execute on function public.app_award_group_configuration_is_canonical(integer) to authenticated;
grant execute on function public.app_schema_version() to authenticated;

comment on function public.app_rhodes_award_group_template() is
  'Οι τέσσερις σταθερές ομάδες των δέκα Δημοτικών Ενοτήτων του Δήμου Ρόδου.';
comment on function public.app_award_group_configuration_is_canonical(integer) is
  'Ελέγχει ότι το έτος χρησιμοποιεί ακριβώς τις τέσσερις ενσωματωμένες ομάδες και καθαρό όριο 30.000 ευρώ.';

commit;
