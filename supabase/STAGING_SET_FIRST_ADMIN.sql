-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΜΟΝΟ ΓΙΑ ΤΟ ΚΕΝΟ PROJECT promitheies-rodou-staging
-- Απόδοση ρόλου admin στον μοναδικό επιβεβαιωμένο δοκιμαστικό χρήστη.
--
-- Το αρχείο σταματά χωρίς αλλαγή αν:
--   • υπάρχουν μηδέν ή περισσότεροι από ένας χρήστες Auth,
--   • ο μοναδικός χρήστης δεν είναι επιβεβαιωμένος,
--   • λείπει το αντίστοιχο προφίλ εφαρμογής,
--   • έχουν ήδη δημιουργηθεί αιτήματα, μελέτες, συμβάσεις ή δελτία.
--
-- ΜΗΝ εκτελεστεί σε παραγωγικό project.
-- ============================================================================

begin;

do $$
declare
  v_user_id uuid;
  v_user_count integer;
  v_schema_version text;
  v_unit_count integer;
  v_group_count integer;
  v_material_count integer;
begin
  select public.app_schema_version() into v_schema_version;
  select count(*) into v_unit_count from public.municipal_units;
  select count(*) into v_group_count from public.procurement_groups;
  select count(*) into v_material_count from public.materials;

  if v_unit_count <> 11
     or not (
       (v_schema_version = '36.5.1' and v_group_count = 14 and v_material_count = 918)
       or
       (v_schema_version = '36.5.5' and v_group_count = 22 and v_material_count = 1096)
       or
       (v_schema_version = '36.6.0' and v_group_count = 22 and v_material_count = 1096)
       or
       (v_schema_version = '36.6.1' and v_group_count = 22 and v_material_count = 1096)
     ) then
    raise exception
      'ΑΚΥΡΩΣΗ: δεν αναγνωρίστηκε το αναμενόμενο κενό staging (schema %, μονάδες %, ομάδες %, είδη %).',
      v_schema_version, v_unit_count, v_group_count, v_material_count;
  end if;

  select count(*) into v_user_count from auth.users;
  if v_user_count <> 1 then
    raise exception
      'ΑΚΥΡΩΣΗ: αναμενόταν ακριβώς ένας δοκιμαστικός χρήστης Auth, βρέθηκαν %.',
      v_user_count;
  end if;

  select u.id
  into v_user_id
  from auth.users u
  where u.email_confirmed_at is not null;

  if v_user_id is null then
    raise exception 'ΑΚΥΡΩΣΗ: ο μοναδικός δοκιμαστικός χρήστης δεν είναι επιβεβαιωμένος.';
  end if;

  if not exists (select 1 from public.profiles p where p.id = v_user_id) then
    raise exception 'ΑΚΥΡΩΣΗ: δεν βρέθηκε προφίλ εφαρμογής για τον δοκιμαστικό χρήστη.';
  end if;

  if exists (select 1 from public.unit_requests)
     or exists (select 1 from public.locked_studies)
     or exists (select 1 from public.mo_contracts)
     or exists (select 1 from public.mo_orders) then
    raise exception
      'ΑΚΥΡΩΣΗ: το project δεν είναι πλέον κενό. Ο ρόλος πρέπει να αποδοθεί με στοχευμένο διοικητικό έλεγχο.';
  end if;

  update public.profiles
  set role = 'admin',
      municipal_unit_id = null,
      updated_at = now()
  where id = v_user_id;

  insert into public.user_app_permissions (
    user_id, can_supervise, updated_at, updated_by
  ) values (
    v_user_id, true, now(), v_user_id
  )
  on conflict (user_id) do update
  set can_supervise = true,
      updated_at = now(),
      updated_by = v_user_id;
end
$$;

commit;

select
  p.role,
  p.municipal_unit_id,
  coalesce(ap.can_supervise, false) as can_supervise
from public.profiles p
left join public.user_app_permissions ap on ap.user_id = p.id;
