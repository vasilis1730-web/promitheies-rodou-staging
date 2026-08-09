-- ============================================================================
-- v36.6.4 FINAL MIGRATION
-- 1. Κοινός validator save/copy/import/lock απαιτεί ενεργό είδος της ομάδας.
-- 2. Νέα/τροποποιημένη γραμμή αιτήματος απαιτεί ενεργό είδος της ίδιας ομάδας.
-- 3. Μόνο αφού εφαρμοστούν όλα τα v36.6.4 invariants δηλώνεται schema 36.6.4.
-- ============================================================================

begin;

create or replace function public.app_validate_request_lines(
  p_group_id bigint,
  p_lines jsonb
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Οι γραμμές αιτήματος πρέπει να είναι πίνακας JSON.';
  end if;
  if jsonb_array_length(p_lines) > 5000 then
    raise exception 'Το αίτημα υπερβαίνει το μέγιστο πλήθος 5.000 γραμμών.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_lines) x(value)
    group by coalesce(nullif(x.value ->> 'material_id', ''), 'code:' || coalesce(x.value ->> 'material_code', ''))
    having count(*) > 1
  ) then
    raise exception 'Το ίδιο είδος εμφανίζεται περισσότερες από μία φορές στο αίτημα.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_lines) x(value)
    where coalesce(x.value ->> 'material_id', x.value ->> 'material_code', '') = ''
       or coalesce(x.value ->> 'quantity', '') !~ '^[+-]?[0-9]+([.][0-9]+)?$'
       or coalesce(x.value ->> 'unit_price', '') !~ '^[+-]?[0-9]+([.][0-9]+)?$'
       or (x.value ->> 'quantity')::numeric < 0
       or (x.value ->> 'unit_price')::numeric < 0
       or (
         coalesce(x.value ->> 'comments', '') <> '__hidden__'
         and (x.value ->> 'quantity')::numeric <= 0
       )
       or (
         coalesce(x.value ->> 'comments', '') = '__hidden__'
         and (x.value ->> 'quantity')::numeric <> 0
       )
  ) then
    raise exception 'Κάθε γραμμή απαιτεί έγκυρο είδος, μη αρνητική τιμή και θετική ποσότητα (ή μηδέν μόνο για κρυφό είδος).';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(p_lines) x(value)
    where (
      select count(*)
      from public.materials m
      where m.group_id::bigint = p_group_id
        and m.is_active is true
        and (
          (nullif(x.value ->> 'material_id', '') is not null and m.id::text = x.value ->> 'material_id')
          or (
            nullif(x.value ->> 'material_id', '') is null
            and nullif(x.value ->> 'material_code', '') is not null
            and m.code = x.value ->> 'material_code'
          )
        )
    ) <> 1
  ) then
    raise exception 'Το αίτημα περιέχει άγνωστο, ανενεργό, διπλό ή ξένο προς την ομάδα είδος.';
  end if;
end;
$$;

revoke all on function public.app_validate_request_lines(bigint,jsonb)
  from public, anon, authenticated;

create or replace function public.app_request_line_catalog_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from public.unit_requests r
    join public.materials m
      on m.id = new.material_id
     and m.group_id = r.group_id
     and m.is_active is true
    where r.id = new.request_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'Η γραμμή αιτήματος απαιτεί ενεργό είδος/εργασία της ίδιας ομάδας.';
  end if;
  return new;
end;
$$;

revoke all on function public.app_request_line_catalog_guard()
  from public, anon, authenticated;

drop trigger if exists trg_request_lines_catalog_guard on public.request_lines;
create trigger trg_request_lines_catalog_guard
  before insert or update of request_id, material_id
  on public.request_lines
  for each row execute function public.app_request_line_catalog_guard();

create or replace function public.app_schema_version()
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select '36.6.4'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

commit;
