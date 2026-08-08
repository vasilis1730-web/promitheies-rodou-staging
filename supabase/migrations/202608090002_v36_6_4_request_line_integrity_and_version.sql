-- ============================================================================
-- v36.6.4 FINAL MIGRATION
-- 1. Νέα/τροποποιημένη γραμμή αιτήματος απαιτεί ενεργό είδος της ίδιας ομάδας.
-- 2. Μόνο αφού εφαρμοστούν όλα τα v36.6.4 invariants δηλώνεται schema 36.6.4.
-- ============================================================================

begin;

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
