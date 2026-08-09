-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΦΑΣΗ 5 / RLS & PRIVILEGE HARDENING
--
-- Βάση αναφοράς: schema 36.6.6.
-- Δεν αλλάζει το application/schema compatibility contract: η εφαρμογή
-- παραμένει συμβατή με REQUIRED_SCHEMA_VERSION 36.6.6.
--
-- Στόχοι:
-- 1. Κανένα public-schema function να μην είναι RPC-callable από PUBLIC/anon
--    εκτός αν δοθεί ρητό μεταγενέστερο GRANT.
-- 2. Τα μελλοντικά app objects που δημιουργούνται από τον postgres owner να
--    ξεκινούν deny-by-default για anon/authenticated και να αποκτούν client
--    privileges μόνο με explicit GRANT στη migration που τα εισάγει.
-- 3. Δύο legacy tables (mo_projects / mo_counters) που δεν χρησιμοποιούνται
--    από το σημερινό frontend να μην παραμένουν εκτεθειμένα σε browser roles.
-- 4. Να διατηρηθούν ανέπαφα όλα τα explicit authenticated grants των ενεργών
--    RPCs / RLS helpers, άρα να μην αλλάξει καμία παραγωγική ροή.
--
-- Η migration δεν μεταβάλλει επιχειρησιακά δεδομένα.
-- ============================================================================

begin;

select pg_advisory_xact_lock(hashtext('promitheies_rodou_phase5_privilege_hardening'));

do $$
declare
  v_version text;
begin
  if to_regprocedure('public.app_schema_version()') is null then
    raise exception 'Λείπει η public.app_schema_version().';
  end if;
  select public.app_schema_version() into v_version;
  if v_version <> '36.6.6' then
    raise exception 'Το Phase 5 privilege hardening απαιτεί schema 36.6.6. Βρέθηκε: %', coalesce(v_version,'NULL');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- A. CURRENT FUNCTION SURFACE
-- PostgreSQL δίνει EXECUTE σε PUBLIC σε functions από προεπιλογή. Τα ενεργά
-- browser RPCs έχουν ήδη explicit GRANT TO authenticated, οπότε το revoke από
-- PUBLIC/anon δεν τα επηρεάζει.
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;

-- Ο anon ρόλος δεν χρειάζεται κανένα direct table/sequence privilege στην app.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

-- ---------------------------------------------------------------------------
-- B. FUTURE OBJECTS — OPT-IN PRIVILEGES
-- Εφαρμόζεται στα αντικείμενα που θα δημιουργεί ο postgres owner από επόμενες
-- migrations. Δεν πειράζουμε τα Supabase-managed default ACLs άλλων owners
-- (π.χ. supabase_admin / storage / graphql).
-- ---------------------------------------------------------------------------
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all on tables from anon, authenticated;

alter default privileges for role postgres in schema public
  revoke all on sequences from anon, authenticated;

-- ---------------------------------------------------------------------------
-- C. LEGACY / UNUSED BROWSER SURFACE
-- Το τρέχον index.html δεν χρησιμοποιεί mo_projects ή mo_counters. Εσωτερικές
-- SECURITY DEFINER functions εξακολουθούν να μπορούν να τα προσπελάσουν με τα
-- δικαιώματα owner όπου χρειάζεται.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('public.mo_projects') is not null then
    revoke all on table public.mo_projects from anon, authenticated;
    drop policy if exists mo_projects_select on public.mo_projects;
    drop policy if exists mo_projects_manage on public.mo_projects;
  end if;

  if to_regclass('public.mo_counters') is not null then
    revoke all on table public.mo_counters from anon, authenticated;
    drop policy if exists mo_counters_select on public.mo_counters;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- D. ASSERTIONS — αποτυχία/rollback αν το hardening δεν πέτυχε.
-- ---------------------------------------------------------------------------
do $$
declare
  v_bad bigint;
begin
  select count(*) into v_bad
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public'
    and p.prokind in ('f','p')
    and (
      has_function_privilege('anon',p.oid,'EXECUTE')
      or exists (
        select 1
        from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where a.grantee=0 and a.privilege_type='EXECUTE'
      )
    );
  if v_bad <> 0 then
    raise exception 'Phase 5: παρέμειναν % public functions εκτελέσιμες από PUBLIC/anon.',v_bad;
  end if;

  select count(*) into v_bad
  from pg_class c
  join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public'
    and c.relkind in ('r','p','v','m','f')
    and (
      has_table_privilege('anon',c.oid,'SELECT')
      or has_table_privilege('anon',c.oid,'INSERT')
      or has_table_privilege('anon',c.oid,'UPDATE')
      or has_table_privilege('anon',c.oid,'DELETE')
    );
  if v_bad <> 0 then
    raise exception 'Phase 5: ο anon διατηρεί direct access σε % public relations.',v_bad;
  end if;

  if to_regclass('public.mo_projects') is not null and (
    has_table_privilege('authenticated','public.mo_projects','SELECT')
    or has_table_privilege('authenticated','public.mo_projects','INSERT')
    or has_table_privilege('authenticated','public.mo_projects','UPDATE')
    or has_table_privilege('authenticated','public.mo_projects','DELETE')
  ) then
    raise exception 'Phase 5: το legacy public.mo_projects παραμένει προσβάσιμο από authenticated.';
  end if;

  if to_regclass('public.mo_counters') is not null and (
    has_table_privilege('authenticated','public.mo_counters','SELECT')
    or has_table_privilege('authenticated','public.mo_counters','INSERT')
    or has_table_privilege('authenticated','public.mo_counters','UPDATE')
    or has_table_privilege('authenticated','public.mo_counters','DELETE')
  ) then
    raise exception 'Phase 5: το legacy public.mo_counters παραμένει προσβάσιμο από authenticated.';
  end if;
end;
$$;

commit;

comment on schema public is
  'Application schema. Phase 5: browser privileges are explicit opt-in; PUBLIC/anon function execution is revoked.';
