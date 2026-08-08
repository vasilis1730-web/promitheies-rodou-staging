-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — v36.6.3 AUTHORIZATION & PRODUCTION READINESS
-- Αρχείο: supabase/migrations/202608080001_v36_6_3_authorization_readiness.sql
--
-- Στόχοι:
--   1. Ανενεργό profile => μηδενική πρόσβαση εφαρμογής/RLS/RPC.
--   2. Οι helper functions role/unit/supervision λαμβάνουν υποχρεωτικά
--      υπόψη το profiles.is_active.
--   3. Καθολικός RESTRICTIVE RLS guard για όλους τους authenticated callers
--      σε κάθε public table που έχει RLS.
--   4. Καθαρισμός περιττών anon grants σε diagnostic views.
--   5. Ενιαία έκδοση schema 36.6.3.
--
-- Επαναλήψιμη. Δεν μεταβάλλει επιχειρησιακά δεδομένα.
-- ============================================================================

begin;

create or replace function public.app_user_is_active()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select auth.uid() is not null
     and exists (
       select 1
       from public.profiles p
       where p.id = auth.uid()
         and p.is_active is true
     )
$$;

revoke all on function public.app_user_is_active() from public, anon;
grant execute on function public.app_user_is_active() to authenticated;

create or replace function public.app_current_role()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select lower(coalesce(p.role::text, ''))
  from public.profiles p
  where p.id = auth.uid()
    and p.is_active is true
  limit 1
$$;

create or replace function public.app_current_unit_id()
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select p.municipal_unit_id::bigint
  from public.profiles p
  where p.id = auth.uid()
    and p.is_active is true
  limit 1
$$;

create or replace function public.app_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select public.app_user_is_active()
     and public.app_current_role() = 'admin'
$$;

create or replace function public.app_can_supervise()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select public.app_user_is_active()
     and (
       public.app_is_admin()
       or exists (
         select 1
         from public.user_app_permissions p
         where p.user_id = auth.uid()
           and p.can_supervise is true
       )
     )
$$;

-- Καθολικό fail-closed φίλτρο: οι υπάρχουσες permissive policies εξακολουθούν
-- να καθορίζουν ΤΙ μπορεί να δει/γράψει ένας ενεργός χρήστης, ενώ αυτή η
-- restrictive policy απαιτεί επιπλέον ο caller να έχει ενεργό profile.
do $$
declare
  r record;
begin
  for r in
    select c.relname as table_name
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r', 'p')
      and c.relrowsecurity
  loop
    execute format(
      'drop policy if exists app_active_user_guard on public.%I',
      r.table_name
    );
    execute format(
      'create policy app_active_user_guard on public.%I as restrictive for all to authenticated using (public.app_user_is_active()) with check (public.app_user_is_active())',
      r.table_name
    );
  end loop;
end;
$$;

-- Το profile bootstrap παραμένει fail-closed: ενεργός admin βλέπει όλους τους
-- χρήστες (και τους inactive για επανενεργοποίηση), ενώ ένας inactive caller
-- κόβεται από το restrictive app_active_user_guard πριν πάρει οποιαδήποτε row.
drop policy if exists profiles_select_scoped on public.profiles;
create policy profiles_select_scoped on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.app_is_admin());

-- Diagnostic views: καμία ανώνυμη παραχώρηση δεν είναι απαραίτητη.
do $$
declare
  v_view text;
begin
  foreach v_view in array array[
    'v_materials_with_price',
    'v_request_lines_detailed',
    'v_request_totals'
  ]
  loop
    if to_regclass('public.' || v_view) is not null then
      execute format('revoke all privileges on public.%I from anon', v_view);
    end if;
  end loop;
end;
$$;

create or replace function public.app_schema_version()
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select '36.6.3'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

commit;
