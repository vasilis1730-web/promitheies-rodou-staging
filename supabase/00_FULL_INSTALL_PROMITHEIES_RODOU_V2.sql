-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ
-- ΠΛΗΡΗΣ ΕΓΚΑΤΑΣΤΑΣΗ «ΠΡΟΜΗΘΕΙΕΣ ΔΗΜΟΥ ΡΟΔΟΥ v2» + «ΔΕΛΤΙΑ ΥΛΙΚΟΥ v36»
-- Αρχείο: 00_FULL_INSTALL_PROMITHEIES_RODOU_V2.sql
--
-- ΠΡΟΟΡΙΣΜΟΣ:
--   ΝΕΟ και ΚΕΝΟ Supabase project της v2.
--   ΜΗΝ εκτελεστεί στο παλιό παραγωγικό project.
--
-- ΠΕΡΙΕΧΟΜΕΝΑ:
--   Α. Βασικό schema εφαρμογής και ασφαλείς RLS policies.
--   Β. Ρόλος central, κλειδωμένες μελέτες, tender overrides, admin RPC.
--   Γ. Πλήρης κατάλογος 14 ομάδων / 918 ειδών (2026 v2).
--   Δ. Πλήρες υποσύστημα Δελτίων Υλικού (mo_*).
--   Ε. Αυτόματος τελικός έλεγχος.
--
-- ΣΗΜΕΙΩΣΗ:
--   Τα δύο αρχεία πηγής δεν περιείχαν κατάλογο «Υπηρεσιών».
--   Δημιουργείται η υποδομή domain='service', αλλά δεν εισάγονται επινοημένες
--   ομάδες ή εργασίες. Η ενότητα Υπηρεσιών θα παραμείνει κενή μέχρι να
--   προστεθεί ο πραγματικός κατάλογός της.
-- ============================================================================

-- ============================================================================
-- ΜΕΡΟΣ Α — Βασικό schema
-- ============================================================================

-- =============================================================
-- Εφαρμογή Προμηθειών Υλικών Δήμου Ρόδου
-- Αρχείο: supabase_schema.sql
-- Σκοπός: Πίνακες, δικαιώματα, αρχικά δεδομένα και views για την εφαρμογή promitheies.html
-- Εκτέλεση: Supabase Dashboard -> SQL Editor -> Run
-- =============================================================

begin;

create extension if not exists pgcrypto;

-- -------------------------------------------------------------
-- 1. Βοηθητικοί τύποι
-- -------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_type where typname = 'app_role') then
    create type public.app_role as enum ('admin', 'unit_user', 'viewer', 'central');
  end if;

  if not exists (select 1 from pg_type where typname = 'request_status') then
    create type public.request_status as enum ('draft', 'saved', 'cleaned', 'exported', 'locked');
  end if;
end $$;

-- -------------------------------------------------------------
-- 2. Βασικοί πίνακες αναφοράς
-- -------------------------------------------------------------
create table if not exists public.municipal_units (
  id smallserial primary key,
  slug text not null unique,
  name text not null unique,
  short_name text not null,
  sort_order smallint not null unique,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.procurement_groups (
  id smallserial primary key,
  code text not null unique,
  name text not null unique,
  short_name text not null,
  sort_order smallint not null unique,
  domain text not null default 'procurement'
    check (domain in ('procurement', 'service')),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Προφίλ χρήστη. Το id ταυτίζεται με auth.users.id.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text,
  full_name text,
  role public.app_role not null default 'viewer',
  municipal_unit_id smallint references public.municipal_units(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profile_role_unit_consistency check (
    (role = 'unit_user' and municipal_unit_id between 1 and 10)
    or (role = 'central' and municipal_unit_id = 11)
    or (role in ('admin', 'viewer') and municipal_unit_id is null)
  )
);

-- -------------------------------------------------------------
-- 3. Μητρώο υλικών και τιμών
-- -------------------------------------------------------------
create table if not exists public.materials (
  id uuid primary key default gen_random_uuid(),
  group_id smallint not null references public.procurement_groups(id),
  code text unique,
  name text not null,
  short_name text,
  subcategory text,
  unit text not null,
  cpv text,
  technical_specs text,
  standards text,
  ce_required boolean not null default false,
  notes_for_tender text,
  default_unit_price numeric(14,4),
  is_active boolean not null default true,
  sort_order integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint positive_default_price check (default_unit_price is null or default_unit_price >= 0)
);

create table if not exists public.material_aliases (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete cascade,
  alias text not null,
  source_note text,
  created_at timestamptz not null default now(),
  unique(material_id, alias)
);

create table if not exists public.price_observations (
  id uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.materials(id) on delete cascade,
  observed_year integer,
  municipal_unit_id smallint references public.municipal_units(id),
  source_title text,
  source_file text,
  original_description text,
  unit text not null,
  unit_price numeric(14,4) not null,
  quantity numeric(14,3),
  total_cost numeric(14,4),
  method_note text,
  is_compatible boolean not null default true,
  created_at timestamptz not null default now(),
  constraint positive_observed_price check (unit_price >= 0)
);

-- -------------------------------------------------------------
-- 4. Δελτία προμηθειών ανά Δημοτική Ενότητα / ομάδα / έτος
-- -------------------------------------------------------------
create table if not exists public.unit_requests (
  id uuid primary key default gen_random_uuid(),
  municipal_unit_id smallint not null references public.municipal_units(id),
  group_id smallint not null references public.procurement_groups(id),
  request_year integer not null default extract(year from now())::integer,
  title text,
  status public.request_status not null default 'draft',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  saved_at timestamptz,
  cleaned_at timestamptz,
  locked_at timestamptz,
  unique(municipal_unit_id, group_id, request_year)
);

create table if not exists public.request_lines (
  request_id uuid not null references public.unit_requests(id) on delete cascade,
  material_id uuid not null references public.materials(id),
  quantity numeric(14,3) not null default 0,
  unit_price numeric(14,4) not null default 0,
  line_status public.request_status not null default 'draft',
  comments text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  subtotal numeric(14,4) generated always as (round(quantity * unit_price, 4)) stored,
  primary key (request_id, material_id),
  constraint non_negative_quantity check (quantity >= 0),
  constraint non_negative_unit_price check (unit_price >= 0)
);

create table if not exists public.saved_versions (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.unit_requests(id) on delete cascade,
  action text not null check (action in ('save', 'save_clean', 'export_excel',
    'tender_document', 'lock', 'unlock', 'copy', 'import', 'cancel_lock')),
  snapshot jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.export_jobs (
  id uuid primary key default gen_random_uuid(),
  request_id uuid references public.unit_requests(id) on delete set null,
  municipal_unit_id smallint references public.municipal_units(id),
  group_id smallint references public.procurement_groups(id),
  export_type text not null check (export_type in ('excel', 'tender_html', 'tender_pdf', 'tender_docx')),
  scope text not null check (scope in ('unit_group', 'unit_all_groups', 'municipality_group', 'municipality_all_groups')),
  file_name text,
  payload jsonb,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

-- -------------------------------------------------------------
-- 5. Indexes
-- -------------------------------------------------------------
create index if not exists idx_profiles_unit on public.profiles(municipal_unit_id);
create index if not exists idx_materials_group on public.materials(group_id, is_active, sort_order, name);
create index if not exists idx_material_aliases_material on public.material_aliases(material_id);
create index if not exists idx_price_observations_material on public.price_observations(material_id, is_compatible, observed_year);
create index if not exists idx_unit_requests_lookup on public.unit_requests(municipal_unit_id, group_id, request_year);
create index if not exists idx_request_lines_material on public.request_lines(material_id);

-- -------------------------------------------------------------
-- 6. Trigger updated_at
-- -------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_profiles_updated_at on public.profiles;
create trigger trg_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists trg_materials_updated_at on public.materials;
create trigger trg_materials_updated_at
before update on public.materials
for each row execute function public.set_updated_at();

drop trigger if exists trg_unit_requests_updated_at on public.unit_requests;
create trigger trg_unit_requests_updated_at
before update on public.unit_requests
for each row execute function public.set_updated_at();

drop trigger if exists trg_request_lines_updated_at on public.request_lines;
create trigger trg_request_lines_updated_at
before update on public.request_lines
for each row execute function public.set_updated_at();

-- -------------------------------------------------------------
-- 7. Helper functions για RLS και εφαρμογή
-- -------------------------------------------------------------
create or replace function public.current_user_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select role
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.current_user_unit_id()
returns smallint
language sql
stable
security definer
set search_path = public
as $$
  select municipal_unit_id
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() = 'admin', false);
$$;

create or replace function public.can_access_unit(p_unit_id smallint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.current_user_role() in ('admin', 'viewer', 'central')
    or (public.current_user_role() = 'unit_user' and public.current_user_unit_id() = p_unit_id),
    false
  );
$$;

create or replace function public.can_write_unit(p_unit_id smallint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.current_user_role() = 'admin'
    or (public.current_user_role() = 'unit_user' and public.current_user_unit_id() = p_unit_id),
    false
  );
$$;

create or replace function public.get_or_create_unit_request(
  p_municipal_unit_id smallint,
  p_group_id smallint,
  p_request_year integer default extract(year from now())::integer
)
returns public.unit_requests
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_request public.unit_requests;
begin
  if not public.can_write_unit(p_municipal_unit_id) then
    raise exception 'Δεν επιτρέπεται πρόσβαση στη συγκεκριμένη Δημοτική Ενότητα.' using errcode = '42501';
  end if;

  select * into v_request
  from public.unit_requests
  where municipal_unit_id = p_municipal_unit_id
    and group_id = p_group_id
    and request_year = p_request_year;

  if v_request.id is null then
    insert into public.unit_requests (municipal_unit_id, group_id, request_year, created_by, updated_by, title)
    values (
      p_municipal_unit_id,
      p_group_id,
      p_request_year,
      auth.uid(),
      auth.uid(),
      'Δελτίο προμήθειας ' || p_request_year
    )
    returning * into v_request;
  end if;

  return v_request;
end;
$$;

-- -------------------------------------------------------------
-- 8. Views
-- -------------------------------------------------------------
create or replace view public.v_materials_with_price
with (security_invoker = true)
as
select
  m.*,
  coalesce(avg(po.unit_price) filter (where po.is_compatible = true and po.unit = m.unit), m.default_unit_price, 0)::numeric(14,4) as suggested_unit_price,
  count(po.id) filter (where po.is_compatible = true and po.unit = m.unit) as price_sample_count,
  min(po.unit_price) filter (where po.is_compatible = true and po.unit = m.unit)::numeric(14,4) as min_observed_price,
  max(po.unit_price) filter (where po.is_compatible = true and po.unit = m.unit)::numeric(14,4) as max_observed_price
from public.materials m
left join public.price_observations po on po.material_id = m.id
group by m.id;

create or replace view public.v_request_lines_detailed
with (security_invoker = true)
as
select
  ur.id as request_id,
  ur.request_year,
  ur.status as request_status,
  mu.id as municipal_unit_id,
  mu.name as municipal_unit_name,
  mu.short_name as municipal_unit_short_name,
  pg.id as group_id,
  pg.name as group_name,
  m.id as material_id,
  m.code as material_code,
  m.name as material_name,
  m.short_name as material_short_name,
  m.subcategory,
  m.unit,
  m.technical_specs,
  m.standards,
  m.ce_required,
  rl.quantity,
  rl.unit_price,
  rl.subtotal,
  rl.line_status,
  rl.comments,
  rl.updated_at
from public.request_lines rl
join public.unit_requests ur on ur.id = rl.request_id
join public.municipal_units mu on mu.id = ur.municipal_unit_id
join public.procurement_groups pg on pg.id = ur.group_id
join public.materials m on m.id = rl.material_id;

create or replace view public.v_request_totals
with (security_invoker = true)
as
select
  ur.id as request_id,
  ur.request_year,
  ur.status,
  ur.municipal_unit_id,
  mu.name as municipal_unit_name,
  ur.group_id,
  pg.name as group_name,
  count(rl.material_id) filter (where rl.quantity > 0) as items_count,
  coalesce(sum(rl.quantity) filter (where rl.quantity > 0), 0)::numeric(14,3) as total_quantity_not_comparable,
  coalesce(sum(rl.subtotal), 0)::numeric(14,2) as net_total,
  round(coalesce(sum(rl.subtotal), 0) * 0.24, 2)::numeric(14,2) as vat_24,
  round(coalesce(sum(rl.subtotal), 0) * 1.24, 2)::numeric(14,2) as gross_total
from public.unit_requests ur
join public.municipal_units mu on mu.id = ur.municipal_unit_id
join public.procurement_groups pg on pg.id = ur.group_id
left join public.request_lines rl on rl.request_id = ur.id
where public.can_access_unit(ur.municipal_unit_id)
group by ur.id, mu.name, pg.name;

-- -------------------------------------------------------------
-- 9. Row Level Security
-- -------------------------------------------------------------
alter table public.municipal_units enable row level security;
alter table public.procurement_groups enable row level security;
alter table public.profiles enable row level security;
alter table public.materials enable row level security;
alter table public.material_aliases enable row level security;
alter table public.price_observations enable row level security;
alter table public.unit_requests enable row level security;
alter table public.request_lines enable row level security;
alter table public.saved_versions enable row level security;
alter table public.export_jobs enable row level security;

-- Καθαρισμός παλιών policies, ώστε το script να ξανατρέχει χωρίς διπλότυπα.
do $$
declare
  r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in (
        'municipal_units','procurement_groups','profiles','materials','material_aliases',
        'price_observations','unit_requests','request_lines','saved_versions','export_jobs'
      )
  loop
    execute format('drop policy if exists %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

create policy municipal_units_read_authenticated
on public.municipal_units for select
to authenticated
using (is_active = true or public.is_admin());

create policy procurement_groups_read_authenticated
on public.procurement_groups for select
to authenticated
using (is_active = true or public.is_admin());

create policy profiles_select_own_or_admin
on public.profiles for select
to authenticated
using (id = auth.uid() or public.is_admin());

create policy profiles_update_admin
on public.profiles for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy materials_read_authenticated
on public.materials for select
to authenticated
using (is_active = true or public.is_admin());

create policy materials_write_admin
on public.materials for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy material_aliases_read_authenticated
on public.material_aliases for select
to authenticated
using (exists (select 1 from public.materials m where m.id = material_id and (m.is_active = true or public.is_admin())));

create policy material_aliases_write_admin
on public.material_aliases for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy price_observations_read_authenticated
on public.price_observations for select
to authenticated
using (exists (select 1 from public.materials m where m.id = material_id and (m.is_active = true or public.is_admin())));

create policy price_observations_write_admin
on public.price_observations for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

create policy unit_requests_select_allowed
on public.unit_requests for select
to authenticated
using (public.can_access_unit(municipal_unit_id));

create policy unit_requests_insert_allowed
on public.unit_requests for insert
to authenticated
with check (public.can_write_unit(municipal_unit_id));

create policy unit_requests_update_allowed
on public.unit_requests for update
to authenticated
using (public.can_write_unit(municipal_unit_id) and status <> 'locked')
with check (public.can_write_unit(municipal_unit_id));

create policy unit_requests_delete_admin
on public.unit_requests for delete
to authenticated
using (public.is_admin());

create policy request_lines_select_allowed
on public.request_lines for select
to authenticated
using (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_access_unit(ur.municipal_unit_id)
  )
);

create policy request_lines_insert_allowed
on public.request_lines for insert
to authenticated
with check (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_write_unit(ur.municipal_unit_id)
      and ur.status <> 'locked'
  )
);

create policy request_lines_update_allowed
on public.request_lines for update
to authenticated
using (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_write_unit(ur.municipal_unit_id)
      and ur.status <> 'locked'
  )
)
with check (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_write_unit(ur.municipal_unit_id)
      and ur.status <> 'locked'
  )
);

create policy request_lines_delete_allowed
on public.request_lines for delete
to authenticated
using (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_write_unit(ur.municipal_unit_id)
      and ur.status <> 'locked'
  )
);

create policy saved_versions_select_allowed
on public.saved_versions for select
to authenticated
using (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_access_unit(ur.municipal_unit_id)
  )
);

create policy saved_versions_insert_allowed
on public.saved_versions for insert
to authenticated
with check (
  exists (
    select 1 from public.unit_requests ur
    where ur.id = request_id
      and public.can_write_unit(ur.municipal_unit_id)
  )
);

create policy export_jobs_select_allowed
on public.export_jobs for select
to authenticated
using (
  public.is_admin()
  or (municipal_unit_id is not null and public.can_access_unit(municipal_unit_id))
);

create policy export_jobs_insert_allowed
on public.export_jobs for insert
to authenticated
with check (
  public.is_admin()
  or (municipal_unit_id is not null and public.can_write_unit(municipal_unit_id))
);

-- -------------------------------------------------------------
-- 10. Αρχικά δεδομένα: Δημοτικές Ενότητες και ομάδες
-- -------------------------------------------------------------
insert into public.municipal_units (id, slug, name, short_name, sort_order) values
(1, 'archangelos', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΡΧΑΓΓΕΛΟΥ', 'ΑΡΧΑΓΓΕΛΟΥ', 1),
(2, 'atavyrs', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΑΒΥΡΟΥ', 2),
(3, 'afantou', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΦΑΝΤΟΥ', 'ΑΦΑΝΤΟΥ', 3),
(4, 'ialysos', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΙΑΛΥΣΟΥ', 'ΙΑΛΥΣΟΥ', 4),
(5, 'kallithea', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΛΛΙΘΕΑΣ', 'ΚΑΛΛΙΘΕΑΣ', 5),
(6, 'kameiros', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΚΑΜΕΙΡΟΥ', 'ΚΑΜΕΙΡΟΥ', 6),
(7, 'lindos', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΛΙΝΔΙΩΝ', 'ΛΙΝΔΙΩΝ', 7),
(8, 'notia-rodos', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', 'ΝΟΤΙΑΣ ΡΟΔΟΥ', 8),
(9, 'petaloudes', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΠΕΤΑΛΟΥΔΩΝ', 'ΠΕΤΑΛΟΥΔΩΝ', 9),
(10, 'rodos', 'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', 'ΡΟΔΟΥ', 10),
(11, 'dimos-rodou', 'ΔΗΜΟΣ ΡΟΔΟΥ', 'ΔΗΜΟΣ ΡΟΔΟΥ', 11)
on conflict (id) do update set
  slug = excluded.slug,
  name = excluded.name,
  short_name = excluded.short_name,
  sort_order = excluded.sort_order,
  is_active = true;

select setval(
  pg_get_serial_sequence('public.municipal_units', 'id'),
  greatest((select max(id) from public.municipal_units), 11),
  true
);

insert into public.procurement_groups (code, name, short_name, sort_order, domain) values
('electrical', 'ΗΛΕΚΤΡΟΛΟΓΙΚΑ ΥΛΙΚΑ', 'Ηλεκτρολογικά', 1, 'procurement'),
('building', 'ΟΙΚΟΔΟΜΙΚΑ ΥΛΙΚΑ', 'Οικοδομικά', 2, 'procurement'),
('aggregates', 'ΑΔΡΑΝΗ ΥΛΙΚΑ', 'Αδρανή', 3, 'procurement'),
('asphalt', 'ΑΣΦΑΛΤΙΚΑ', 'Ασφαλτικά', 4, 'procurement'),
('hardware', 'ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'Κιγκαλερία', 5, 'procurement'),
('air_conditioning', 'ΚΛΙΜΑΤΙΣΤΙΚΑ', 'Κλιματιστικά', 6, 'procurement'),
('plumbing', 'ΥΔΡΑΥΛΙΚΑ ΥΛΙΚΑ', 'Υδραυλικά', 7, 'procurement'),
('paint', 'ΕΛΑΙΟΧΡΩΜΑΤΙΣΜΟΙ', 'Ελαιοχρωματισμοί', 8, 'procurement'),
('signage', 'ΥΛΙΚΑ ΣΗΜΑΝΣΗΣ', 'Σήμανση', 9, 'procurement')
on conflict (code) do update set
  name = excluded.name,
  short_name = excluded.short_name,
  sort_order = excluded.sort_order,
  domain = excluded.domain,
  is_active = true;

-- -------------------------------------------------------------
-- 11. Ενδεικτικό αρχικό μητρώο υλικών.
-- Θα εμπλουτιστεί με πλήρη εισαγωγή όλων των ειδών από τα αρχεία.
-- -------------------------------------------------------------
with g as (select id, code from public.procurement_groups)
insert into public.materials (group_id, code, name, short_name, subcategory, unit, technical_specs, standards, ce_required, default_unit_price, sort_order)
select g.id, x.code, x.name, x.short_name, x.subcategory, x.unit, x.technical_specs, x.standards, x.ce_required, x.default_unit_price, x.sort_order
from g
join (values
-- Ηλεκτρολογικά
('electrical','EL-001','Καλώδιο NYY J1VV-U 3x1,5 mm²','Καλώδιο NYY 3x1,5','Καλώδια','m','Καλώδιο χαλκού σταθερής εγκατάστασης με μόνωση και μανδύα PVC, ονομαστικής τάσης 0,6/1kV.','ΕΛΟΤ/ΕΝ για καλώδια χαμηλής τάσης',true,0.82,1),
('electrical','EL-002','Καλώδιο NYY J1VV-U 3x2,5 mm²','Καλώδιο NYY 3x2,5','Καλώδια','m','Καλώδιο χαλκού σταθερής εγκατάστασης με μόνωση και μανδύα PVC, ονομαστικής τάσης 0,6/1kV.','ΕΛΟΤ/ΕΝ για καλώδια χαμηλής τάσης',true,1.27,2),
('electrical','EL-003','Καλώδιο NYY J1VV-U 5x2,5 mm²','Καλώδιο NYY 5x2,5','Καλώδια','m','Καλώδιο χαλκού σταθερής εγκατάστασης με μόνωση και μανδύα PVC.','ΕΛΟΤ/ΕΝ για καλώδια χαμηλής τάσης',true,2.00,3),
('electrical','EL-004','Καλώδιο εύκαμπτο NYLHY A03VV-F 3x1,5 mm²','Καλώδιο NYLHY 3x1,5','Καλώδια','m','Εύκαμπτο καλώδιο PVC για ήπια μηχανική καταπόνηση.','ΕΛΟΤ/ΕΝ για εύκαμπτα καλώδια',true,0.87,4),
('electrical','EL-005','Καλώδιο εύκαμπτο NYLHY A03VV-F 3x2,5 mm²','Καλώδιο NYLHY 3x2,5','Καλώδια','m','Εύκαμπτο καλώδιο PVC για ήπια μηχανική καταπόνηση.','ΕΛΟΤ/ΕΝ για εύκαμπτα καλώδια',true,1.32,5),
('electrical','EL-006','Καλώδιο UTP Cat6, 4 ζευγών','Καλώδιο UTP Cat6','Καλώδια ασθενών ρευμάτων','m','Καλώδιο δικτύου U/UTP κατηγορίας 6.','ISO/IEC 11801, ANSI/TIA 568',true,0.58,6),
('electrical','EL-007','Αυτόματη ασφάλεια ράγας τύπου C 10A','Ασφάλεια C 10A','Υλικά πινάκων','τεμ.','Μικροαυτόματος διακόπτης προστασίας τύπου C, ικανότητα διακοπής σύμφωνα με EN 60898.','EN 60898',true,3.23,7),
('electrical','EL-008','Αυτόματη ασφάλεια ράγας τύπου C 16A','Ασφάλεια C 16A','Υλικά πινάκων','τεμ.','Μικροαυτόματος διακόπτης προστασίας τύπου C.','EN 60898',true,3.00,8),
('electrical','EL-009','Αυτόματη ασφάλεια ράγας τύπου C 20A','Ασφάλεια C 20A','Υλικά πινάκων','τεμ.','Μικροαυτόματος διακόπτης προστασίας τύπου C.','EN 60898',true,2.85,9),
('electrical','EL-010','Ρελέ διαρροής 4x40A','Ρελέ διαρροής 4x40A','Υλικά πινάκων','τεμ.','Διακόπτης διαφυγής έντασης τετραπολικός 40A.','EN 61008 / EN 61009',true,44.59,10),
('electrical','EL-011','Ρελέ φορτίου 4x40A','Ρελέ φορτίου 4x40A','Υλικά πινάκων','τεμ.','Ρελέ ισχύος/φορτίου τετραπολικό 40A.','EN 60947',true,36.20,11),
('electrical','EL-012','Λαμπτήρας LED E27 12W, 6000K','Λαμπτήρας LED E27 12W','Λαμπτήρες','τεμ.','Λαμπτήρας LED με λυχνιολαβή E27, ψυχρό λευκό.','CE',true,3.20,12),
('electrical','EL-013','Λαμπτήρας LED GU10 έως 6W, 6000K','Λαμπτήρας LED GU10','Λαμπτήρες','τεμ.','Λαμπτήρας LED με λυχνιολαβή GU10.','CE',true,2.75,13),
('electrical','EL-014','Ρευματοδότης Schuko χωνευτός με πλαίσιο','Πρίζα Schuko χωνευτή','Διακόπτες - ρευματοδότες','τεμ.','Ρευματοδότης τύπου Schuko για χωνευτή εγκατάσταση με πλαίσιο.','CE',true,2.15,14),
('electrical','EL-015','Ρευματοδότης Schuko εξωτερικού χώρου','Πρίζα Schuko εξωτερική','Διακόπτες - ρευματοδότες','τεμ.','Ρευματοδότης τύπου Schuko εξωτερικής εγκατάστασης.','CE',true,2.58,15),
('electrical','EL-016','Διακόπτης φωτισμού απλός χωνευτός με πλαίσιο','Διακόπτης απλός','Διακόπτες - ρευματοδότες','τεμ.','Χωνευτός διακόπτης φωτισμού με πλαίσιο.','CE',true,2.40,16),
('electrical','EL-017','Διακόπτης φωτισμού αλέ-ρετούρ χωνευτός με πλαίσιο','Διακόπτης αλέ-ρετούρ','Διακόπτες - ρευματοδότες','τεμ.','Χωνευτός διακόπτης φωτισμού αλέ-ρετούρ με πλαίσιο.','CE',true,2.35,17),
('electrical','EL-018','Προβολέας LED στεγανός IP65 50W, 6000K','Προβολέας LED 50W','Προβολείς - φωτιστικά','τεμ.','Στεγανός προβολέας LED IP65, φωτεινής ροής τουλάχιστον 6000 lm.','CE, IP65',true,11.00,18),
('electrical','EL-019','Φωτοκύτταρο δημοτικού φωτισμού 16A','Φωτοκύτταρο 16A','Αισθητήρες - αυτοματισμοί','τεμ.','Φωτοκύτταρο ελέγχου δημοτικού φωτισμού.','CE',true,23.96,19),

-- Οικοδομικά
('building','BL-001','Τσιμέντο Portland γκρι, σάκος 25 kg','Τσιμέντο γκρι 25 kg','Τσιμέντα - κονιάματα','τεμ.','Τσιμέντο Portland σε σφραγισμένο σάκο 25 kg, πρόσφατης παραγωγής.','ΕΛΟΤ EN 197-1, EN 197-2',true,5.33,1),
('building','BL-002','Τσιμέντο λευκό, σάκος 25 kg','Τσιμέντο λευκό 25 kg','Τσιμέντα - κονιάματα','τεμ.','Λευκό τσιμέντο σε σφραγισμένο σάκο 25 kg.','ΕΛΟΤ EN 197-1, EN 196-1',true,9.12,2),
('building','BL-003','Ασβεστόπολτος, σάκος 15 kg','Ασβεστόπολτος 15 kg','Τσιμέντα - κονιάματα','τεμ.','Ασβεστόπολτος καλά σβησμένος και ωριμασμένος, χωρίς ξένες προσμίξεις.','EN 459-1',true,6.05,3),
('building','BL-004','Ασβέστης σε πολτό, συσκευασία 20 kg','Ασβέστης 20 kg','Τσιμέντα - κονιάματα','τεμ.','Ασβέστης σε πολτό, κολλώδους υφής, χωρίς ξένες προσμίξεις.','EN 459-1',true,4.97,4),
('building','BL-005','Οπτόπλινθος 6x9x19 cm','Οπτόπλινθος 6x9x19','Τοιχοποιία','τεμ.','Οπτόπλινθος διαστάσεων 6x9x19 cm.','ΕΛΟΤ ΤΠ 1501-03-02-02-00',true,0.39,5),
('building','BL-006','Οπτόπλινθος 9x12x19 cm','Οπτόπλινθος 9x12x19','Τοιχοποιία','τεμ.','Οπτόπλινθος διαστάσεων 9x12x19 cm.','ΕΛΟΤ ΤΠ 1501-03-02-02-00',true,0.47,6),
('building','BL-007','Τσιμεντόλιθος 39x15x19 cm','Τσιμεντόλιθος','Τοιχοποιία','τεμ.','Τσιμεντόλιθος διαστάσεων 39x15x19 cm.','EN 771-3, EN 772',true,1.45,7),
('building','BL-008','Κόλλα πλακιδίων ρητινούχα, σάκος 25 kg','Κόλλα πλακιδίων 25 kg','Συγκολλητικά','τεμ.','Ρητινούχα κόλλα πλακιδίων υψηλής πρόσφυσης για εσωτερική και εξωτερική χρήση.','EN 12004, EN 1348',true,15.46,8),
('building','BL-009','Σιδηρός οπλισμός Φ12, μήκους 4,00 m','Σίδηρος Φ12 4m','Οπλισμοί','τεμ.','Ράβδος σιδηρού οπλισμού κυκλικής διατομής Φ12.','Ισχύουσες ΕΤΕΠ / κανονισμοί οπλισμού',true,7.30,9),
('building','BL-010','Σιδηρός οπλισμός Φ16, μήκους 4,00 m','Σίδηρος Φ16 4m','Οπλισμοί','τεμ.','Ράβδος σιδηρού οπλισμού κυκλικής διατομής Φ16.','Ισχύουσες ΕΤΕΠ / κανονισμοί οπλισμού',true,4.07,10),
('building','BL-011','Πλέγμα οπλισμού Τ139, διαστάσεων 2x5 m','Πλέγμα Τ139','Οπλισμοί','τεμ.','Δομικό πλέγμα οπλισμού Τ139 διαστάσεων 2x5 m.','ΕΛΟΤ ΤΠ 1501-01-02-01-00',true,23.27,11),
('building','BL-012','Πρόχυτο κράσπεδο σκυροδέματος','Πρόχυτο κράσπεδο','Προκατασκευασμένα στοιχεία','τεμ.','Πρόχυτο κράσπεδο σκυροδέματος με απότμηση.','ΕΛΟΤ ΤΠ 1501-05-02-01-00',true,6.68,12),
('building','BL-013','Τσιμέντο ταχείας πήξεως, σάκος 25 kg','Τσιμέντο ταχείας πήξεως 25 kg','Τσιμέντα - κονιάματα','τεμ.','Συνδετικό υλικό ταχείας πήξεως και ανάπτυξης αντοχών.','CE',true,17.30,13),
('building','BL-014','Προκατασκευασμένο φρεάτιο στεγανό 40x40 cm','Φρεάτιο 40x40','Προκατασκευασμένα στοιχεία','τεμ.','Προκατασκευασμένο φρεάτιο από σκυρόδεμα, στεγανό, διαστάσεων 40x40 cm.','ΕΛΟΤ ΤΠ 1501-08-06-08-06',true,42.93,14),
('building','BL-015','Προκατασκευασμένο φρεάτιο στεγανό 30x30 cm','Φρεάτιο 30x30','Προκατασκευασμένα στοιχεία','τεμ.','Προκατασκευασμένο φρεάτιο από σκυρόδεμα, στεγανό, διαστάσεων 30x30 cm.','ΕΛΟΤ ΤΠ 1501-08-06-08-06',true,20.22,15),
('building','BL-016','Πλάκες πεζοδρομίου 40x40 ή 50x50 cm','Πλάκες πεζοδρομίου','Επιστρώσεις','m²','Πλάκες πεζοδρομίου βαριάς κυκλοφορίας, πάχους περίπου 5 cm.','EN 1339, EN 13369',true,2.50,16),

-- Κιγκαλερία
('hardware','HW-001','Στραντζαριστή κοιλοδοκός γαλβανισμένη 40x40x2 mm, μήκους 5 m','Στραντζαριστό γαλβ. 40x40x2','Μεταλλικές διατομές','m','Γαλβανισμένη στραντζαριστή κοιλοδοκός βαρέως τύπου.','CE όπου απαιτείται',false,3.50,1),
('hardware','HW-002','Στραντζαριστή κοιλοδοκός γαλβανισμένη 50x30x2 mm, μήκους 5 m','Στραντζαριστό γαλβ. 50x30x2','Μεταλλικές διατομές','m','Γαλβανισμένη στραντζαριστή κοιλοδοκός βαρέως τύπου.','CE όπου απαιτείται',false,3.40,2),
('hardware','HW-003','Γωνία σιδήρου 30x30x3 mm, βέργα 6 m','Γωνία 30x30x3','Μεταλλικές διατομές','kg','Ισοσκελής γωνία σιδήρου.','CE όπου απαιτείται',false,1.40,3),
('hardware','HW-004','Κοιλοδοκός γαλβανισμένη 50x50x3 mm, βέργα 6 m','Κοιλοδοκός γαλβ. 50x50x3','Μεταλλικές διατομές','τεμ.','Γαλβανισμένη κοιλοδοκός τετραγωνικής διατομής.','CE όπου απαιτείται',false,50.00,4),
('hardware','HW-005','Λάμα γαλβανισμένη 30x3 mm, βέργα 4 m','Λάμα γαλβ. 30x3','Μεταλλικές διατομές','kg','Γαλβανισμένη χαλύβδινη λάμα.','CE όπου απαιτείται',false,1.50,5),
('hardware','HW-006','Λαμαρίνα γαλβανισμένη μπακλαβωτή 1000x2000x3 mm','Λαμαρίνα μπακλαβωτή 3mm','Λαμαρίνες','τεμ.','Γαλβανισμένη μπακλαβωτή λαμαρίνα.','CE όπου απαιτείται',false,120.00,6),
('hardware','HW-007','Βίδες αυτοδιάτρητες M4,2x38 mm, κουτί 100 τεμ.','Βίδες αυτοδιάτρητες','Συνδετικά','τεμ.','Αυτοδιάτρητες βίδες γαλβανισμένες.','DIN / EN κατά περίπτωση',false,9.00,7),
('hardware','HW-008','Παξιμάδια ατσάλινα DIN 934 M6-M8','Παξιμάδια DIN 934','Συνδετικά','τεμ.','Ατσάλινα παξιμάδια κατά DIN 934.','DIN 934',false,0.01,8),
('hardware','HW-009','Ροδέλες γαλβανισμένες στενές DIN 125 M6-M8-M10','Ροδέλες DIN 125','Συνδετικά','τεμ.','Γαλβανισμένες ροδέλες στενές.','DIN 125',false,0.009,9),
('hardware','HW-010','Μεταλλικός μεντεσές σιδερόπορτας με φτερό Φ18, μήκους 100 mm','Μεντεσές σιδερόπορτας Φ18','Μεντεσέδες','τεμ.','Μεταλλικός μεντεσές για σιδερόπορτα.','',false,3.80,10),
('hardware','HW-011','Κλειδαριά ασφαλείας για σιδηρόπορτα','Κλειδαριά ασφαλείας σιδηρόπορτας','Κλειδαριές','τεμ.','Κλειδαριά ασφαλείας κατάλληλη για σιδηρόπορτες.','',false,10.00,11),
('hardware','HW-012','Λουκέτο ορειχάλκινο Νο 50','Λουκέτο ορειχάλκινο Νο 50','Λουκέτα','τεμ.','Ορειχάλκινο λουκέτο.','',false,6.00,12),

-- Ελαιοχρωματισμοί
('paint','PA-001','Ακρυλικό πλαστικό χρώμα λευκό εξωτερικού χώρου, 10 lt','Ακρυλικό εξωτερικού 10lt','Χρώματα','τεμ.','Ακρυλικό χρώμα εξωτερικής τοιχοποιίας, λευκό, υψηλής πρόσφυσης και αντοχής στις καιρικές συνθήκες.','CE, κριτήρια VOC',true,28.00,1),
('paint','PA-002','Πλαστικό χρώμα λευκό εσωτερικού χώρου, 10 lt','Πλαστικό εσωτερικού 10lt','Χρώματα','τεμ.','Πλαστικό χρώμα εσωτερικής χρήσης, λευκό, κατάλληλο για σοβά, μπετόν και σπατουλαρισμένες επιφάνειες.','CE, κριτήρια VOC',true,24.00,2),
('paint','PA-003','Βασικό πλαστικό χρωμάτων, συσκευασία 750 ml','Βασικό πλαστικό 750ml','Χρωστικές βάσεις','τεμ.','Πλαστικό χρώμα ματ για χρωματισμό πλαστικών και ακρυλικών χρωμάτων.','CE, κριτήρια VOC',true,5.00,3),
('paint','PA-004','Κύλινδρος βαφής πλαστικού Νο 18','Ρολό πλαστικού Νο 18','Αναλώσιμα βαφής','τεμ.','Πολυεστερικός κύλινδρος βαφής για πλαστικά και ακρυλικά χρώματα, πλάτους 18 cm.','',false,2.50,4),
('paint','PA-005','Πινέλο βαφής Νο 2΄΄','Πινέλο Νο 2','Αναλώσιμα βαφής','τεμ.','Επίπεδο πινέλο βαφής με ξύλινη λαβή και συνθετική τρίχα.','',false,1.80,5),
('paint','PA-006','Σιλικόνη διάφανη αντιμυκητιακή, φύσιγγα 280-330 ml','Σιλικόνη διάφανη','Σφραγιστικά','τεμ.','Διάφανη αντιμυκητιακή όξινη σιλικόνη γενικής χρήσης.','CE',true,3.50,6),
('paint','PA-007','Ακρυλικό σφραγιστικό λευκό, φύσιγγα 280 ml','Ακρυλική σιλικόνη λευκή','Σφραγιστικά','τεμ.','Ακρυλικό σφραγιστικό ενός συστατικού για αρμούς και ρωγμές.','CE',true,2.80,7),
('paint','PA-008','Στεγανωτικό ελαστομερές ταρατσών, 9 lt','Στεγανωτικό ταρατσών 9lt','Στεγανωτικά','τεμ.','Ελαστομερές στεγανοποιητικό υλικό υψηλής αντοχής στην υπεριώδη ακτινοβολία και στο νερό.','CE',true,39.00,8),
('paint','PA-009','Σπρέι ακρυλικής βάσης διαφόρων χρωμάτων, 400 ml','Σπρέι χρώματος 400ml','Χρώματα σπρέι','τεμ.','Σπρέι ακρυλικής βάσης για εσωτερικές και εξωτερικές επιφάνειες.','CE',true,4.00,9),

-- Placeholder υλικά για τις υπό εμπλουτισμό ομάδες
('aggregates','AG-001','Άμμος λατομείου κατάλληλης κοκκομετρίας','Άμμος λατομείου','Αδρανή','m³','Αδρανές υλικό κατάλληλης κοκκομετρικής διαβάθμισης.','Ισχύουσες ΕΤΕΠ / EN για αδρανή',true,0,1),
('asphalt','AS-001','Έτοιμο ψυχρό ασφαλτόμιγμα σε σάκο','Ψυχρό ασφαλτόμιγμα','Ασφαλτικά','τεμ.','Έτοιμο ψυχρό ασφαλτόμιγμα για επισκευές οδοστρώματος.','Ισχύουσες προδιαγραφές ασφαλτικών υλικών',true,0,1),
('air_conditioning','AC-001','Κλιματιστική μονάδα inverter 9.000 BTU/h','Κλιματιστικό 9.000 BTU','Κλιματιστικές μονάδες','τεμ.','Κλιματιστική μονάδα τεχνολογίας inverter.','CE, ενεργειακή σήμανση',true,0,1),
('plumbing','PL-001','Σωλήνας PVC ύδρευσης/αποχέτευσης ενδεικτικής διαμέτρου','Σωλήνας PVC','Σωληνώσεις','m','Πλαστικός σωλήνας για υδραυλικές εφαρμογές.','CE / EN κατά περίπτωση',true,0,1),
('signage','SG-001','Πινακίδα οδικής σήμανσης ΚΟΚ, πλήρης','Πινακίδα ΚΟΚ','Πινακίδες','τεμ.','Πινακίδα οδικής σήμανσης σύμφωνα με τις ισχύουσες προδιαγραφές.','ΚΟΚ, ισχύουσες προδιαγραφές σήμανσης',true,0,1)
) as x(group_code, code, name, short_name, subcategory, unit, technical_specs, standards, ce_required, default_unit_price, sort_order)
on g.code = x.group_code
on conflict (code) do update set
  name = excluded.name,
  short_name = excluded.short_name,
  subcategory = excluded.subcategory,
  unit = excluded.unit,
  technical_specs = excluded.technical_specs,
  standards = excluded.standards,
  ce_required = excluded.ce_required,
  default_unit_price = excluded.default_unit_price,
  sort_order = excluded.sort_order,
  is_active = true;

-- Ενδεικτικά aliases, ώστε η εφαρμογή να μπορεί να κρατήσει παλιές/λαϊκές περιγραφές.
insert into public.material_aliases (material_id, alias, source_note)
select m.id, a.alias, a.source_note
from public.materials m
join (values
('EL-014','Πρίζα εσωτερική χωνευτή','Κανονικοποίηση σε ρευματοδότη Schuko χωνευτό'),
('EL-015','Πρίζα εξωτερική','Κανονικοποίηση σε ρευματοδότη Schuko εξωτερικού χώρου'),
('EL-017','Διακόπτης A/R','Κανονικοποίηση σε διακόπτη αλέ-ρετούρ'),
('BL-005','ΟΠΤΟΠΛΙΝΘΟΙ 6 ΟΠΩΝ 6x9x19','Κανονικοποίηση οπτόπλινθου'),
('BL-006','ΟΠΤΟΠΛΙΝΘΟΙ 12 ΟΠΩΝ 9x12x19','Κανονικοποίηση οπτόπλινθου'),
('BL-008','Ρητινούχα κόλλα πλακιδίων 25 kg','Κανονικοποίηση κόλλας πλακιδίων'),
('PA-006','Σιλικόνη διάφανη','Κανονικοποίηση σφραγιστικού')
) as a(code, alias, source_note)
on m.code = a.code
on conflict (material_id, alias) do nothing;

-- -------------------------------------------------------------
-- 12. Αυτόματη δημιουργία profile μετά από sign up
-- Προσοχή: ο χρήστης θα δημιουργείται ως viewer μέχρι ο admin να του ορίσει ρόλο/Δ.Ε.
-- -------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, full_name, role, municipal_unit_id, is_active)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', new.email),
    'viewer',
    null,
    true
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

commit;

-- ============================================================================
-- ΜΕΡΟΣ Β — Πυρήνας v36: ρόλος central, κλειδωμένες μελέτες,
--               προσαρμογές τεύχους και ασφαλής διαχείριση χρηστών
-- ============================================================================

-- Αν το αρχείο εκτελεστεί σε βάση όπου ο τύπος προϋπήρχε χωρίς central,
-- η προσθήκη γίνεται σε ξεχωριστή συναλλαγή πριν χρησιμοποιηθεί η νέα τιμή.
begin;
alter type public.app_role add value if not exists 'central';
commit;

begin;

alter table public.procurement_groups
  add column if not exists domain text not null default 'procurement';

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.procurement_groups'::regclass
      and conname = 'procurement_groups_domain_check'
  ) then
    alter table public.procurement_groups
      add constraint procurement_groups_domain_check
      check (domain in ('procurement', 'service'));
  end if;
end $$;

alter table public.materials
  add column if not exists cpv text;

alter table public.profiles
  alter column role set default 'viewer';

alter table public.profiles
  drop constraint if exists unit_user_must_have_unit;

alter table public.profiles
  drop constraint if exists profile_role_unit_consistency;

alter table public.profiles
  add constraint profile_role_unit_consistency check (
    (role = 'unit_user' and municipal_unit_id between 1 and 10)
    or (role = 'central' and municipal_unit_id = 11)
    or (role in ('admin', 'viewer') and municipal_unit_id is null)
  );

insert into public.municipal_units
  (id, slug, name, short_name, sort_order, is_active)
values
  (11, 'dimos-rodou', 'ΔΗΜΟΣ ΡΟΔΟΥ', 'ΔΗΜΟΣ ΡΟΔΟΥ', 11, true)
on conflict (id) do update set
  slug = excluded.slug,
  name = excluded.name,
  short_name = excluded.short_name,
  sort_order = excluded.sort_order,
  is_active = true;

select setval(
  pg_get_serial_sequence('public.municipal_units', 'id'),
  greatest((select max(id) from public.municipal_units), 11),
  true
);

create or replace function public.current_user_role()
returns public.app_role
language sql
stable
security definer
set search_path = public
as $$
  select role
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.current_user_unit_id()
returns smallint
language sql
stable
security definer
set search_path = public
as $$
  select municipal_unit_id
  from public.profiles
  where id = auth.uid()
    and is_active = true
  limit 1;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(public.current_user_role() = 'admin', false);
$$;

create or replace function public.can_access_unit(p_unit_id smallint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.current_user_role() in ('admin', 'viewer', 'central')
    or (
      public.current_user_role() = 'unit_user'
      and public.current_user_unit_id() = p_unit_id
    ),
    false
  );
$$;

create or replace function public.can_write_unit(p_unit_id smallint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.current_user_role() = 'admin'
    or (
      public.current_user_role() = 'unit_user'
      and public.current_user_unit_id() = p_unit_id
    ),
    false
  );
$$;

-- Κλειδωμένες μελέτες. Το lines κρατά το ακριβές στιγμιότυπο των ειδών.
create table if not exists public.locked_studies (
  id uuid primary key default gen_random_uuid(),
  municipal_unit_id smallint not null
    references public.municipal_units(id) on delete restrict,
  group_id smallint not null
    references public.procurement_groups(id) on delete restrict,
  request_year integer not null,
  source_request_id uuid
    references public.unit_requests(id) on delete set null,
  seq integer not null,
  label text,
  net_total numeric(14,2) not null default 0
    check (net_total >= 0),
  item_count integer not null default 0
    check (item_count >= 0),
  lines jsonb not null default '[]'::jsonb,
  supplier_name text,
  kimdis_url text,
  locked_by uuid references auth.users(id) on delete set null
    default auth.uid(),
  locked_at timestamptz not null default now(),
  unique (municipal_unit_id, group_id, request_year, seq)
);

create index if not exists idx_locked_studies_context
  on public.locked_studies
  (municipal_unit_id, group_id, request_year, seq);

create index if not exists idx_locked_studies_source_request
  on public.locked_studies(source_request_id);

-- Διοικητικές προσαρμογές στα παραγόμενα τεύχη.
create table if not exists public.tender_overrides (
  id text primary key,
  data jsonb not null default '{}'::jsonb,
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

drop trigger if exists trg_tender_overrides_updated_at
  on public.tender_overrides;
create trigger trg_tender_overrides_updated_at
before update on public.tender_overrides
for each row execute function public.set_updated_at();

-- Η εφαρμογή διαχειριστή αλλάζει email/κωδικό υπάρχοντος χρήστη.
-- Η συνάρτηση εκτελείται μόνο όταν ο καλών είναι ενεργός administrator.
create or replace function public.admin_set_user_credentials(
  p_user_id uuid,
  p_new_email text,
  p_new_password text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_email text;
begin
  if not public.is_admin() then
    raise exception 'Δεν επιτρέπεται η διαχείριση χρηστών.'
      using errcode = '42501';
  end if;

  v_email := lower(trim(coalesce(p_new_email, '')));

  if v_email = '' then
    raise exception 'Το email δεν μπορεί να είναι κενό.'
      using errcode = '22023';
  end if;

  if p_new_password is not null and length(p_new_password) < 6 then
    raise exception 'Ο νέος κωδικός πρέπει να έχει τουλάχιστον 6 χαρακτήρες.'
      using errcode = '22023';
  end if;

  update auth.users
  set email = v_email,
      email_confirmed_at = coalesce(email_confirmed_at, now()),
      updated_at = now()
  where id = p_user_id;

  if not found then
    raise exception 'Δεν βρέθηκε ο χρήστης.'
      using errcode = 'P0002';
  end if;

  if p_new_password is not null and p_new_password <> '' then
    update auth.users
    set encrypted_password = crypt(p_new_password, gen_salt('bf')),
        updated_at = now()
    where id = p_user_id;
  end if;

  update public.profiles
  set email = v_email,
      updated_at = now()
  where id = p_user_id;
end;
$$;

alter table public.locked_studies enable row level security;
alter table public.tender_overrides enable row level security;

drop policy if exists locked_studies_select_allowed
  on public.locked_studies;
create policy locked_studies_select_allowed
on public.locked_studies for select
to authenticated
using (public.can_access_unit(municipal_unit_id));

drop policy if exists locked_studies_insert_allowed
  on public.locked_studies;
create policy locked_studies_insert_allowed
on public.locked_studies for insert
to authenticated
with check (
  public.can_write_unit(municipal_unit_id)
  and locked_by = auth.uid()
);

drop policy if exists locked_studies_update_admin
  on public.locked_studies;
create policy locked_studies_update_admin
on public.locked_studies for update
to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists locked_studies_delete_admin
  on public.locked_studies;
create policy locked_studies_delete_admin
on public.locked_studies for delete
to authenticated
using (public.is_admin());

drop policy if exists tender_overrides_select_authenticated
  on public.tender_overrides;
create policy tender_overrides_select_authenticated
on public.tender_overrides for select
to authenticated
using (true);

drop policy if exists tender_overrides_manage_admin
  on public.tender_overrides;
create policy tender_overrides_manage_admin
on public.tender_overrides for all
to authenticated
using (public.is_admin())
with check (public.is_admin());

-- Ρητά δικαιώματα επειδή στο νέο project είναι κλειστή η αυτόματη
-- έκθεση/παραχώρηση δικαιωμάτων νέων πινάκων.
revoke all on table public.locked_studies from anon;
revoke all on table public.tender_overrides from anon;
grant select, insert, update, delete
  on table public.locked_studies to authenticated;
grant select, insert, update, delete
  on table public.tender_overrides to authenticated;

revoke all on function public.admin_set_user_credentials(uuid, text, text)
  from public, anon;
grant execute
  on function public.admin_set_user_credentials(uuid, text, text)
  to authenticated;

commit;

-- ============================================================================
-- ΜΕΡΟΣ Β2 — Ρητά API grants για τους βασικούς πίνακες
-- ============================================================================

begin;

grant usage on schema public to authenticated;

revoke all on table
  public.municipal_units,
  public.procurement_groups,
  public.profiles,
  public.materials,
  public.material_aliases,
  public.price_observations,
  public.unit_requests,
  public.request_lines,
  public.saved_versions,
  public.export_jobs
from anon;

grant select on table
  public.municipal_units,
  public.procurement_groups,
  public.profiles,
  public.materials,
  public.material_aliases,
  public.price_observations
to authenticated;

grant insert, update, delete on table
  public.profiles,
  public.materials,
  public.material_aliases,
  public.price_observations
to authenticated;

grant select, insert, update, delete on table
  public.unit_requests,
  public.request_lines,
  public.saved_versions,
  public.export_jobs
to authenticated;

grant select on table
  public.v_materials_with_price,
  public.v_request_lines_detailed,
  public.v_request_totals
to authenticated;

revoke all on function public.current_user_role()
  from public, anon;
revoke all on function public.current_user_unit_id()
  from public, anon;
revoke all on function public.is_admin()
  from public, anon;
revoke all on function public.can_access_unit(smallint)
  from public, anon;
revoke all on function public.can_write_unit(smallint)
  from public, anon;
revoke all on function public.get_or_create_unit_request(smallint, smallint, integer)
  from public, anon;

grant execute on function public.current_user_role()
  to authenticated;
grant execute on function public.current_user_unit_id()
  to authenticated;
grant execute on function public.is_admin()
  to authenticated;
grant execute on function public.can_access_unit(smallint)
  to authenticated;
grant execute on function public.can_write_unit(smallint)
  to authenticated;
grant execute on function public.get_or_create_unit_request(smallint, smallint, integer)
  to authenticated;

-- Trigger functions δεν πρέπει να καλούνται απευθείας από API clients.
revoke all on function public.set_updated_at()
  from public, anon, authenticated;
revoke all on function public.handle_new_user()
  from public, anon, authenticated;

commit;


-- ============================================================================
-- ΜΕΡΟΣ Γ — Πλήρης κατάλογος 14 ομάδων / 918 ειδών
-- ============================================================================

-- =====================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ
-- ΠΛΗΡΗΣ ΑΝΤΙΚΑΤΑΣΤΑΣΗ ΚΕΝΤΡΙΚΟΥ ΚΑΤΑΛΟΓΟΥ 14 ΟΜΑΔΩΝ ΥΛΙΚΩΝ
-- Πηγή: 14 ελεγμένα αρχεία Excel του ZIP «ΟΜΑΔΕΣ ΥΛΙΚΩΝ.zip»
-- Νέος κατάλογος: 918 είδη
-- Έκδοση v2: διορθώθηκε η 5η τιμή is_active στις 14 εγγραφές ομάδων.
--
-- ΣΗΜΑΝΤΙΚΟ:
-- * Διαγράφονται φυσικά ΟΛΑ τα παλιά υλικά των 14 ομάδων.
-- * Διαγράφονται όλες οι παλιές γραμμές ποσοτήτων που συνδέονται με αυτά.
-- * Οι παλιές εγγραφές αντιγράφονται προηγουμένως, ανά ομάδα, στον
--   public.export_jobs ως JSON backup.
-- * Τα δελτία των Δημοτικών Ενοτήτων παραμένουν, αλλά μηδενίζονται και
--   επανέρχονται σε κατάσταση draft.
-- * Δεν εισάγονται ποσότητες, επειδή τα 14 Excel είναι κεντρικοί κατάλογοι
--   και οι στήλες ποσότητας είναι κενές.
-- * Ολόκληρη η διαδικασία είναι μία συναλλαγή. Αν αποτύχει οποιοσδήποτε
--   έλεγχος, γίνεται ROLLBACK και δεν διατηρείται μερική αλλαγή.
--
-- Το 15ο αρχείο «Πίνακας_Οικοδομικού_Υλικού...» δεν χρησιμοποιείται:
-- αποδείχθηκε ακριβώς ίσο με Αδρανή 1–8 + Οικοδομικά 9–108.
-- =====================================================================

begin;

select pg_advisory_xact_lock(hashtext('rhodes_full_catalog_replacement_14_groups_2026'));

alter table public.materials
  add column if not exists cpv text;

-- Προσωρινή αποδέσμευση των μοναδικών sort_order των υφιστάμενων ομάδων.
update public.procurement_groups
set sort_order = (-1000 - id)::smallint
where code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

insert into public.procurement_groups (code, name, short_name, sort_order, domain, is_active)
values
  ('electrical', 'ΗΛΕΚΤΡΟΛΟΓΙΚΟ ΥΛΙΚΟ', 'Ηλεκτρολογικό υλικό', 1, 'procurement', true),
  ('building', 'ΟΙΚΟΔΟΜΙΚΑ ΥΛΙΚΑ', 'Οικοδομικά', 2, 'procurement', true),
  ('aggregates', 'ΑΔΡΑΝΗ ΥΛΙΚΑ', 'Αδρανή', 3, 'procurement', true),
  ('asphalt', 'ΑΣΦΑΛΤΙΚΑ', 'Ασφαλτικά', 4, 'procurement', true),
  ('hardware', 'ΣΙΔΗΡΙΚΑ & ΚΙΓΚΑΛΕΡΙΑ', 'Σιδηρικά - Κιγκαλερία', 5, 'procurement', true),
  ('air_conditioning', 'ΚΛΙΜΑΤΙΣΤΙΚΑ', 'Κλιματιστικά', 6, 'procurement', true),
  ('plumbing', 'ΥΔΡΑΥΛΙΚΟ ΥΛΙΚΟ ΚΤΗΡΙΩΝ', 'Υδραυλικά', 7, 'procurement', true),
  ('paint', 'ΧΡΩΜΑΤΑ & ΣΤΕΓΑΝΩΤΙΚΑ', 'Χρώματα - Στεγανωτικά', 8, 'procurement', true),
  ('signage', 'ΣΗΜΑΝΣΗ', 'Σήμανση', 9, 'procurement', true),
  ('wood', 'ΞΥΛΕΙΑ', 'Ξυλεία', 10, 'procurement', true),
  ('glass', 'ΥΑΛΟΠΙΝΑΚΕΣ & ΠΛΕΞΙΓΚΛΑΣ', 'Υαλοπίνακες - Πλεξιγκλάς', 11, 'procurement', true),
  ('ppe', 'ΜΕΣΑ ΑΤΟΜΙΚΗΣ ΠΡΟΣΤΑΣΙΑΣ (ΜΑΠ)', 'ΜΑΠ', 12, 'procurement', true),
  ('tools', 'ΕΡΓΑΛΕΙΑ & ΑΝΑΛΩΣΙΜΑ', 'Εργαλεία - Αναλώσιμα', 13, 'procurement', true),
  ('urban_equipment', 'ΑΣΤΙΚΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'Αστικός εξοπλισμός', 14, 'procurement', true)
on conflict (code) do update set
  name = excluded.name,
  short_name = excluded.short_name,
  sort_order = excluded.sort_order,
  domain = 'procurement',
  is_active = true;

do $$
declare
  v_group_count integer;
  v_old_material_count integer;
begin
  select count(*)
  into v_group_count
  from public.procurement_groups
  where code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

  if v_group_count <> 14 then
    raise exception 'ΑΚΥΡΩΣΗ: αναμένονταν 14 ομάδες, αλλά βρέθηκαν %.', v_group_count;
  end if;

  select count(*)
  into v_old_material_count
  from public.materials m
  join public.procurement_groups pg on pg.id = m.group_id
  where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

  raise notice 'Παλιά υλικά που θα αντικατασταθούν: %', v_old_material_count;
end
$$;

lock table public.materials in share row exclusive mode;
lock table public.request_lines in share row exclusive mode;
lock table public.unit_requests in share row exclusive mode;

-- Πλήρες αντίγραφο ασφαλείας ανά ομάδα.
insert into public.export_jobs
  (group_id, export_type, scope, file_name, payload, created_at)
select
  pg.id,
  'excel',
  'municipality_group',
  'BACKUP_before_full_catalog_replacement_' || pg.code || '_' ||
    to_char(clock_timestamp(), 'YYYYMMDD_HH24MISS') || '.json',
  jsonb_build_object(
    'operation', 'full_catalog_replacement_14_groups_2026',
    'group', to_jsonb(pg),
    'materials', coalesce((
      select jsonb_agg(to_jsonb(m) order by m.sort_order, m.code)
      from public.materials m
      where m.group_id = pg.id
    ), '[]'::jsonb),
    'request_lines', coalesce((
      select jsonb_agg(to_jsonb(rl) order by rl.request_id, rl.material_id)
      from public.request_lines rl
      join public.materials m on m.id = rl.material_id
      where m.group_id = pg.id
    ), '[]'::jsonb),
    'material_aliases', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.material_id, a.alias)
      from public.material_aliases a
      join public.materials m on m.id = a.material_id
      where m.group_id = pg.id
    ), '[]'::jsonb),
    'price_observations', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.material_id, p.created_at)
      from public.price_observations p
      join public.materials m on m.id = p.material_id
      where m.group_id = pg.id
    ), '[]'::jsonb),
    'unit_requests', coalesce((
      select jsonb_agg(to_jsonb(ur) order by ur.municipal_unit_id, ur.request_year)
      from public.unit_requests ur
      where ur.group_id = pg.id
    ), '[]'::jsonb),
    'backup_created_at', clock_timestamp()
  ),
  now()
from public.procurement_groups pg
where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

-- Αφαίρεση όλων των παλιών ποσοτήτων των 14 ομάδων.
delete from public.request_lines rl
using public.materials m, public.procurement_groups pg
where rl.material_id = m.id
  and m.group_id = pg.id
  and pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

-- Φυσική διαγραφή όλων των παλιών υλικών.
-- material_aliases και price_observations διαγράφονται μέσω ON DELETE CASCADE.
delete from public.materials m
using public.procurement_groups pg
where m.group_id = pg.id
  and pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

-- Τα υφιστάμενα δελτία παραμένουν αλλά καθαρίζονται.
update public.unit_requests ur
set
  status = 'draft',
  saved_at = null,
  cleaned_at = null,
  locked_at = null,
  updated_at = now()
from public.procurement_groups pg
where ur.group_id = pg.id
  and pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[]);

with src (
  group_code, material_code, name, short_name, subcategory, unit,
  cpv, standards, technical_specs, ce_required, notes_for_tender,
  default_unit_price, sort_order
) as (
values
  ('electrical', 'ELR-2026-001', 'Μονόκλωνος αγωγός PVC H07V-U (NYA) 1×1,5 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 0.3, 1),
  ('electrical', 'ELR-2026-002', 'Μονόκλωνος αγωγός PVC H07V-U (NYA) 1×2,5 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 0.45, 2),
  ('electrical', 'ELR-2026-003', 'Μονόκλωνος αγωγός PVC H07V-U (NYA) 1×4 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 0.7, 3),
  ('electrical', 'ELR-2026-004', 'Πολύκλωνος αγωγός PVC H07V-R (NYA) 1×6 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.05, 4),
  ('electrical', 'ELR-2026-005', 'Πολύκλωνος αγωγός PVC H07V-R (NYA) 1×10 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.75, 5),
  ('electrical', 'ELR-2026-006', 'Εύκαμπτος αγωγός PVC H07V-K (NYAF) 1×1,5 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31', NULL, true, NULL, 0.32, 6),
  ('electrical', 'ELR-2026-007', 'Εύκαμπτος αγωγός PVC H07V-K (NYAF) 1×2,5 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31', NULL, true, NULL, 0.48, 7),
  ('electrical', 'ELR-2026-008', 'Εύκαμπτος αγωγός PVC H07V-K (NYAF) 1×4 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31', NULL, true, NULL, 0.75, 8),
  ('electrical', 'ELR-2026-009', 'Εύκαμπτος αγωγός PVC H07V-K (NYAF) 1×6 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31', NULL, true, NULL, 1.1, 9),
  ('electrical', 'ELR-2026-010', 'Εύκαμπτος αγωγός PVC H07V-K (NYAF) 1×10 mm²', NULL, 'ΟΜΑΔΑ Α — ΑΓΩΓΟΙ ΧΑΜΗΛΗΣ ΤΑΣΗΣ (ΜΟΝΟΠΟΛΙΚΟΙ)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31', NULL, true, NULL, 1.85, 10),
  ('electrical', 'ELR-2026-011', 'Καλώδιο τύπου NYM (A05VV-U/R) 2×1,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 0.75, 11),
  ('electrical', 'ELR-2026-012', 'Καλώδιο τύπου NYM 2×2,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.05, 12),
  ('electrical', 'ELR-2026-013', 'Καλώδιο τύπου NYM 3×1,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1, 13),
  ('electrical', 'ELR-2026-014', 'Καλώδιο τύπου NYM 3×2,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.45, 14),
  ('electrical', 'ELR-2026-015', 'Καλώδιο τύπου NYM 3×4 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 2.2, 15),
  ('electrical', 'ELR-2026-016', 'Καλώδιο τύπου NYM 3×6 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 3.1, 16),
  ('electrical', 'ELR-2026-017', 'Καλώδιο τύπου NYM 3×10 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 5.2, 17),
  ('electrical', 'ELR-2026-018', 'Καλώδιο τύπου NYM 4×1,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.3, 18),
  ('electrical', 'ELR-2026-019', 'Καλώδιο τύπου NYM 4×2,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.9, 19),
  ('electrical', 'ELR-2026-020', 'Καλώδιο τύπου NYM 4×4 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 2.9, 20),
  ('electrical', 'ELR-2026-021', 'Καλώδιο τύπου NYM 4×6 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 4.2, 21),
  ('electrical', 'ELR-2026-022', 'Καλώδιο τύπου NYM 4×10 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 6.9, 22),
  ('electrical', 'ELR-2026-023', 'Εύκαμπτο καλώδιο H05VV-F (πρώην NYMHY) 2×0,75 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-11', NULL, true, NULL, 0.55, 23),
  ('electrical', 'ELR-2026-024', 'Εύκαμπτο καλώδιο H05VV-F 2×1,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-11', NULL, true, NULL, 0.8, 24),
  ('electrical', 'ELR-2026-025', 'Εύκαμπτο καλώδιο H05VV-F 3×1,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-11', NULL, true, NULL, 1.05, 25),
  ('electrical', 'ELR-2026-026', 'Εύκαμπτο καλώδιο H05VV-F 3×2,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-11', NULL, true, NULL, 1.55, 26),
  ('electrical', 'ELR-2026-027', 'Εύκαμπτο καλώδιο H05VV-F 4×2,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-11', NULL, true, NULL, 2, 27),
  ('electrical', 'ELR-2026-028', 'Εύκαμπτο καλώδιο H05VV-F 5×2,5 mm²', NULL, 'ΟΜΑΔΑ Β — ΚΑΛΩΔΙΑ ΕΣΩΤΕΡΙΚΗΣ ΕΓΚΑΤΑΣΤΑΣΗΣ (ΕΩΣ 4×10 mm²)', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-11', NULL, true, NULL, 2.55, 28),
  ('electrical', 'ELR-2026-029', 'Καλώδιο ισχύος τύπου NYY (J1VV) 0,6/1 kV 3×1,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1 / ΕΤΕΠ 04-20-02-01', NULL, true, NULL, 1.4, 29),
  ('electrical', 'ELR-2026-030', 'Καλώδιο ισχύος NYY 0,6/1 kV 3×2,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 1.95, 30),
  ('electrical', 'ELR-2026-031', 'Καλώδιο ισχύος NYY 0,6/1 kV 3×4 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 2.8, 31),
  ('electrical', 'ELR-2026-032', 'Καλώδιο ισχύος NYY 0,6/1 kV 3×6 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 3.9, 32),
  ('electrical', 'ELR-2026-033', 'Καλώδιο ισχύος NYY 0,6/1 kV 3×10 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 6.3, 33),
  ('electrical', 'ELR-2026-034', 'Καλώδιο ισχύος NYY 0,6/1 kV 4×1,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 1.8, 34),
  ('electrical', 'ELR-2026-035', 'Καλώδιο ισχύος NYY 0,6/1 kV 4×2,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 2.5, 35),
  ('electrical', 'ELR-2026-036', 'Καλώδιο ισχύος NYY 0,6/1 kV 4×4 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 3.6, 36),
  ('electrical', 'ELR-2026-037', 'Καλώδιο ισχύος NYY 0,6/1 kV 4×6 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 5.1, 37),
  ('electrical', 'ELR-2026-038', 'Καλώδιο ισχύος NYY 0,6/1 kV 4×10 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 8.2, 38),
  ('electrical', 'ELR-2026-039', 'Καλώδιο ισχύος NYY 0,6/1 kV 5×1,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 2.2, 39),
  ('electrical', 'ELR-2026-040', 'Καλώδιο ισχύος NYY 0,6/1 kV 5×2,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 3.1, 40),
  ('electrical', 'ELR-2026-041', 'Καλώδιο ισχύος NYY 0,6/1 kV 5×4 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 4.5, 41),
  ('electrical', 'ELR-2026-042', 'Καλώδιο ισχύος NYY 0,6/1 kV 5×6 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 6.4, 42),
  ('electrical', 'ELR-2026-043', 'Καλώδιο ισχύος NYY 0,6/1 kV 5×10 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 10.5, 43),
  ('electrical', 'ELR-2026-044', 'Μονοπολικό καλώδιο ισχύος NYY 0,6/1 kV 1×10 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 1.95, 44),
  ('electrical', 'ELR-2026-045', 'Μονοπολικό καλώδιο ισχύος NYY 0,6/1 kV 1×16 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525 / IEC 60502-1', NULL, true, NULL, 2.9, 45),
  ('electrical', 'ELR-2026-046', 'Εύκαμπτο ελαστικό καλώδιο βαρέως τύπου H07RN-F 3×1,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525-2-21', NULL, true, NULL, 1.8, 46),
  ('electrical', 'ELR-2026-047', 'Εύκαμπτο ελαστικό καλώδιο H07RN-F 3×2,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525-2-21', NULL, true, NULL, 2.55, 47),
  ('electrical', 'ELR-2026-048', 'Εύκαμπτο ελαστικό καλώδιο H07RN-F 5×2,5 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525-2-21', NULL, true, NULL, 4.1, 48),
  ('electrical', 'ELR-2026-049', 'Εύκαμπτο ελαστικό καλώδιο H07RN-F 5×4 mm²', NULL, 'ΟΜΑΔΑ Γ — ΚΑΛΩΔΙΑ ΙΣΧΥΟΣ / ΕΞΩΤΕΡΙΚΟΥ ΧΩΡΟΥ & ΥΠΟΓΕΙΑ (ΕΩΣ 5×10 mm²)', 'm', '31320000-5', 'ΕΛΟΤ ΕΝ 50525-2-21', NULL, true, NULL, 5.9, 49),
  ('electrical', 'ELR-2026-050', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 6 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 4.8, 50),
  ('electrical', 'ELR-2026-051', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 10 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 4.8, 51),
  ('electrical', 'ELR-2026-052', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 16 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 4.9, 52),
  ('electrical', 'ELR-2026-053', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 20 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 5.1, 53),
  ('electrical', 'ELR-2026-054', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 25 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 5.3, 54),
  ('electrical', 'ELR-2026-055', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 32 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 5.6, 55),
  ('electrical', 'ELR-2026-056', 'Μικροαυτόματος διακόπτης 1P, καμπύλη C, 6 kA, 40 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 6.4, 56),
  ('electrical', 'ELR-2026-057', 'Μικροαυτόματος διακόπτης 1P, καμπύλη B, 6 kA, 16 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 5.3, 57),
  ('electrical', 'ELR-2026-058', 'Μικροαυτόματος διακόπτης 1P+N, καμπύλη C, 6 kA, 16 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 9.8, 58),
  ('electrical', 'ELR-2026-059', 'Μικροαυτόματος διακόπτης 1P+N, καμπύλη C, 6 kA, 25 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 10.6, 59),
  ('electrical', 'ELR-2026-060', 'Μικροαυτόματος διακόπτης 2P, καμπύλη C, 6 kA, 16 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 12.5, 60),
  ('electrical', 'ELR-2026-061', 'Μικροαυτόματος διακόπτης 2P, καμπύλη C, 6 kA, 25 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 13.2, 61),
  ('electrical', 'ELR-2026-062', 'Μικροαυτόματος διακόπτης 2P, καμπύλη C, 6 kA, 40 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 15.5, 62),
  ('electrical', 'ELR-2026-063', 'Μικροαυτόματος διακόπτης 3P, καμπύλη C, 6 kA, 16 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 17.5, 63),
  ('electrical', 'ELR-2026-064', 'Μικροαυτόματος διακόπτης 3P, καμπύλη C, 6 kA, 25 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 18.5, 64),
  ('electrical', 'ELR-2026-065', 'Μικροαυτόματος διακόπτης 3P, καμπύλη C, 6 kA, 32 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 19.5, 65),
  ('electrical', 'ELR-2026-066', 'Μικροαυτόματος διακόπτης 3P, καμπύλη C, 6 kA, 40 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 21, 66),
  ('electrical', 'ELR-2026-067', 'Μικροαυτόματος διακόπτης 3P, καμπύλη C, 6 kA, 50 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 24, 67),
  ('electrical', 'ELR-2026-068', 'Μικροαυτόματος διακόπτης 3P, καμπύλη C, 6 kA, 63 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 27, 68),
  ('electrical', 'ELR-2026-069', 'Μικροαυτόματος διακόπτης 4P, καμπύλη C, 6 kA, 25 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 26, 69),
  ('electrical', 'ELR-2026-070', 'Μικροαυτόματος διακόπτης 4P, καμπύλη C, 6 kA, 40 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 29, 70),
  ('electrical', 'ELR-2026-071', 'Μικροαυτόματος διακόπτης 4P, καμπύλη C, 6 kA, 63 A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 60898-1', NULL, true, NULL, 34, 71),
  ('electrical', 'ELR-2026-072', 'Διακόπτης διαφυγής έντασης (ΔΔΕ/RCCB) 2P, 40 A, 30 mA, τύπου AC', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61008-1', NULL, true, NULL, 28, 72),
  ('electrical', 'ELR-2026-073', 'Διακόπτης διαφυγής έντασης (ΔΔΕ/RCCB) 2P, 63 A, 30 mA, τύπου AC', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61008-1', NULL, true, NULL, 38, 73),
  ('electrical', 'ELR-2026-074', 'Διακόπτης διαφυγής έντασης (ΔΔΕ/RCCB) 4P, 40 A, 30 mA, τύπου AC', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61008-1', NULL, true, NULL, 42, 74),
  ('electrical', 'ELR-2026-075', 'Διακόπτης διαφυγής έντασης (ΔΔΕ/RCCB) 4P, 63 A, 30 mA, τύπου AC', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61008-1', NULL, true, NULL, 52, 75),
  ('electrical', 'ELR-2026-076', 'Διακόπτης διαφυγής έντασης (ΔΔΕ/RCCB) 4P, 40 A, 30 mA, τύπου A', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61008-1', NULL, true, NULL, 58, 76),
  ('electrical', 'ELR-2026-077', 'Μικροαυτόματος-διαφυγής έντασης (RCBO) 1P+N, C16 A, 30 mA', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61009-1', NULL, true, NULL, 32, 77),
  ('electrical', 'ELR-2026-078', 'Μικροαυτόματος-διαφυγής έντασης (RCBO) 1P+N, C25 A, 30 mA', NULL, 'ΟΜΑΔΑ Δ — ΜΙΚΡΟΑΥΤΟΜΑΤΟΙ ΔΙΑΚΟΠΤΕΣ & ΔΙΑΤΑΞΕΙΣ ΠΡΟΣΤΑΣΙΑΣ (ΕΩΣ 63 A)', 'τεμ', '31212000-5', 'ΕΛΟΤ ΕΝ 61009-1', NULL, true, NULL, 34, 78),
  ('electrical', 'ELR-2026-079', 'Συντηκτική ασφάλεια βιδωτή τύπου D (Diazed), πορσελάνης, 16 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 1.2, 79),
  ('electrical', 'ELR-2026-080', 'Συντηκτική ασφάλεια βιδωτή τύπου D (Diazed) 25 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 1.25, 80),
  ('electrical', 'ELR-2026-081', 'Συντηκτική ασφάλεια βιδωτή τύπου D (Diazed) 35 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 1.4, 81),
  ('electrical', 'ELR-2026-082', 'Συντηκτική ασφάλεια βιδωτή τύπου D (Diazed) 50 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 1.6, 82),
  ('electrical', 'ELR-2026-083', 'Συντηκτική ασφάλεια βιδωτή τύπου D (Diazed) 63 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 1.85, 83),
  ('electrical', 'ELR-2026-084', 'Βάση συντηκτικής ασφάλειας πορσελάνης τύπου D, 1P, 63 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 3.2, 84),
  ('electrical', 'ELR-2026-085', 'Πώμα (κοχλιωτό καπάκι) συντηκτικής ασφάλειας τύπου D, πορσελάνης', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-3', NULL, true, NULL, 0.9, 85),
  ('electrical', 'ELR-2026-086', 'Κυλινδρικό τηκτό φυσίγγιο 10×38 mm, χαρακτηριστικής gG, 16 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 0.7, 86),
  ('electrical', 'ELR-2026-087', 'Κυλινδρικό τηκτό φυσίγγιο 10×38 mm, gG, 32 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 0.8, 87),
  ('electrical', 'ELR-2026-088', 'Κυλινδρικό τηκτό φυσίγγιο 14×51 mm, gG, 50 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 1.75, 88),
  ('electrical', 'ELR-2026-089', 'Κυλινδρικό τηκτό φυσίγγιο 22×58 mm, gG, 63 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 2.8, 89),
  ('electrical', 'ELR-2026-090', 'Ασφαλειοθήκη ράγας κυλινδρικών φυσιγγίων 10×38 mm, 1P', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 3.4, 90),
  ('electrical', 'ELR-2026-091', 'Μαχαιρωτή ασφάλεια χαμηλής τάσης τύπου NH00, gG, 63 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 4.5, 91),
  ('electrical', 'ELR-2026-092', 'Μαχαιρωτή ασφάλεια NH00, gG, 100 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 4.8, 92),
  ('electrical', 'ELR-2026-093', 'Μαχαιρωτή ασφάλεια NH1, gG, 160 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 7.5, 93),
  ('electrical', 'ELR-2026-094', 'Μαχαιρωτή ασφάλεια NH2, gG, 250 A', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 12, 94),
  ('electrical', 'ELR-2026-095', 'Βάση μαχαιρωτών ασφαλειών NH00, 3P', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 18, 95),
  ('electrical', 'ELR-2026-096', 'Μονωτική λαβή τοποθέτησης/αφαίρεσης ασφαλειών NH', NULL, 'ΟΜΑΔΑ Ε — ΤΗΚΤΕΣ ΑΣΦΑΛΕΙΕΣ (ΣΥΝΤΗΚΤΙΚΕΣ & ΜΑΧΑΙΡΩΤΕΣ NH)', 'τεμ', '31211300-1', 'ΕΛΟΤ ΕΝ 60269-2', NULL, true, NULL, 14, 96),
  ('electrical', 'ELR-2026-097', 'Πίνακας διανομής εντοιχιζόμενος, 1 σειράς (12 στοιχείων), με θύρα, IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 22, 97),
  ('electrical', 'ELR-2026-098', 'Πίνακας διανομής εντοιχιζόμενος, 2 σειρών (24 στοιχείων), IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 34, 98),
  ('electrical', 'ELR-2026-099', 'Πίνακας διανομής εντοιχιζόμενος, 3 σειρών (36 στοιχείων), IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 48, 99),
  ('electrical', 'ELR-2026-100', 'Πίνακας διανομής εντοιχιζόμενος, 4 σειρών (48 στοιχείων), IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 62, 100),
  ('electrical', 'ELR-2026-101', 'Πίνακας διανομής επιφανειακός, 1 σειράς (12 στοιχείων), IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 20, 101),
  ('electrical', 'ELR-2026-102', 'Πίνακας διανομής επιφανειακός, 2 σειρών (24 στοιχείων), IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 30, 102),
  ('electrical', 'ELR-2026-103', 'Πίνακας διανομής επιφανειακός, 3 σειρών (36 στοιχείων), IP40', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 44, 103),
  ('electrical', 'ELR-2026-104', 'Πίνακας διανομής στεγανός επιφανειακός IP65, 1 σειράς (12 στοιχ.)', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 28, 104),
  ('electrical', 'ELR-2026-105', 'Πίνακας διανομής στεγανός επιφανειακός IP65, 2 σειρών (24 στοιχ.)', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 42, 105),
  ('electrical', 'ELR-2026-106', 'Πίνακας διανομής στεγανός επιφανειακός IP65, 3 σειρών (36 στοιχ.)', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 61439-3', NULL, true, NULL, 60, 106),
  ('electrical', 'ELR-2026-107', 'Πίνακας διανομής μεταλλικός επιδαπέδιος, έως 6 σειρών, IP54, με μετώπη', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211110-2', 'ΕΛΟΤ ΕΝ 61439-2', NULL, true, NULL, 220, 107),
  ('electrical', 'ELR-2026-108', 'Διακόπτης φορτίου-απομονωτής ράγας 2P, 40 A', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60947-3', NULL, false, NULL, 11, 108),
  ('electrical', 'ELR-2026-109', 'Διακόπτης φορτίου-απομονωτής ράγας 4P, 63 A', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60947-3', NULL, false, NULL, 22, 109),
  ('electrical', 'ELR-2026-110', 'Ηλεκτρονόμος ισχύος εγκατάστασης (ρελέ) 2P, 25 A, 230 V', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31200000-8', 'ΕΛΟΤ ΕΝ 61095', NULL, false, NULL, 16, 110),
  ('electrical', 'ELR-2026-111', 'Ηλεκτρονόμος ισχύος εγκατάστασης (ρελέ) 4P, 40 A', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31200000-8', 'ΕΛΟΤ ΕΝ 61095', NULL, false, NULL, 30, 111),
  ('electrical', 'ELR-2026-112', 'Βηματικός ηλεκτρονόμος (ρελέ τηλεχειρισμού/σκάλας) 1P, 16 A', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31200000-8', 'ΕΛΟΤ ΕΝ 60669-2-2', NULL, true, NULL, 18, 112),
  ('electrical', 'ELR-2026-113', 'Απαγωγός υπερτάσεων (SPD) Τύπου 2, 4P, Up ≤ 1,5 kV', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31217000-0', 'ΕΛΟΤ ΕΝ 61643-11', NULL, false, NULL, 95, 113),
  ('electrical', 'ELR-2026-114', 'Ράγα στήριξης οργάνων DIN 35 mm (συμμετρική)', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'm', '31211100-9', 'ΕΛΟΤ ΕΝ 60715', NULL, false, NULL, 2.2, 114),
  ('electrical', 'ELR-2026-115', 'Ζυγός (μπάρα) ουδετέρου/γείωσης ορειχάλκινος, 12 θέσεων', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31218000-7', 'ΕΛΟΤ ΕΝ 61439-1', NULL, true, NULL, 4.5, 115),
  ('electrical', 'ELR-2026-116', 'Διανομέας ζυγού (κτενοειδής μπάρα) μονοπολικός, 12 αναχωρήσεων', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31218000-7', 'ΕΛΟΤ ΕΝ 61439-1', NULL, true, NULL, 7, 116),
  ('electrical', 'ELR-2026-117', 'Ενδεικτική λυχνία ράγας LED, 230 V', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΙΝΑΚΕΣ ΔΙΑΝΟΜΗΣ & ΕΞΑΡΤΗΜΑΤΑ ΠΙΝΑΚΩΝ (1 ΕΩΣ 6 ΣΕΙΡΕΣ)', 'τεμ', '31211100-9', 'ΕΛΟΤ ΕΝ 60947-5-1', NULL, false, NULL, 6.5, 117),
  ('electrical', 'ELR-2026-118', 'Φωτοηλεκτρικός διακόπτης (φωτοκύτταρο) με ενσωματωμένο αισθητήρα, IP44, 16 A, 230 V', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-2-1', NULL, true, NULL, 12, 118),
  ('electrical', 'ELR-2026-119', 'Φωτοηλεκτρικός διακόπτης ράγας 16 A με εξωτερικό αισθητήρα φωτεινότητας IP65', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-2-1', NULL, true, NULL, 22, 119),
  ('electrical', 'ELR-2026-120', 'Χρονοδιακόπτης ράγας ψηφιακός, εβδομαδιαίος, 16 A, 1 διέξοδος', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60730-2-7', NULL, false, NULL, 24, 120),
  ('electrical', 'ELR-2026-121', 'Χρονοδιακόπτης ράγας αναλογικός, ημερήσιος, 16 A', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60730-2-7', NULL, false, NULL, 14, 121),
  ('electrical', 'ELR-2026-122', 'Αστρονομικός (γεωγραφικός) χρονοδιακόπτης ράγας, 16 A', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60730-2-7', NULL, false, NULL, 55, 122),
  ('electrical', 'ELR-2026-123', 'Ανιχνευτής κίνησης υπερύθρων (PIR) επίτοιχος, IP44, 230 V', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-2-1', NULL, true, NULL, 16, 123),
  ('electrical', 'ELR-2026-124', 'Ανιχνευτής κίνησης υπερύθρων (PIR) οροφής 360°, IP20', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-2-1', NULL, true, NULL, 18, 124),
  ('electrical', 'ELR-2026-125', 'Επιτηρητής τάσης/ασυμμετρίας φάσεων ράγας, 3P', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΓΑΝΑ ΕΛΕΓΧΟΥ, ΧΡΟΝΙΣΜΟΥ & ΑΥΤΟΜΑΤΙΣΜΟΥ', 'τεμ', '31200000-8', 'ΕΛΟΤ ΕΝ 60255-26', NULL, false, NULL, 38, 125),
  ('electrical', 'ELR-2026-126', 'Διακόπτης εντοιχιζόμενος μονοπολικός (απλός) 10 A, 250 V, με πλαίσιο', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-1', NULL, true, NULL, 3.5, 126),
  ('electrical', 'ELR-2026-127', 'Διακόπτης εντοιχιζόμενος εναλλαγής (κομιτατέρ) 10 A', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-1', NULL, true, NULL, 3.9, 127),
  ('electrical', 'ELR-2026-128', 'Διακόπτης εντοιχιζόμενος διασταυρώσεως (μεσαίος) 10 A', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-1', NULL, true, NULL, 6.5, 128),
  ('electrical', 'ELR-2026-129', 'Πιεστικός διακόπτης (κομβίο) εντοιχιζόμενος, κανονικά ανοικτός, 10 A', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-1', NULL, true, NULL, 4.2, 129),
  ('electrical', 'ELR-2026-130', 'Διακόπτης στεγανός επιφανειακός IP44, μονοπολικός, 10 A', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31214100-0', 'ΕΛΟΤ ΕΝ 60669-1', NULL, true, NULL, 6, 130),
  ('electrical', 'ELR-2026-131', 'Ρευματοδότης σούκο (τύπου CEE 7/3) εντοιχιζόμενος 2P+E, 16 A, 250 V', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31224100-0', 'ΕΛΟΤ ΕΝ 60884-1', NULL, false, NULL, 4.5, 131),
  ('electrical', 'ELR-2026-132', 'Ρευματοδότης σούκο στεγανός επιφανειακός IP44, 2P+E, 16 A', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31224100-0', 'ΕΛΟΤ ΕΝ 60884-1', NULL, false, NULL, 7.5, 132),
  ('electrical', 'ELR-2026-133', 'Ρευματοδότης βιομηχανικού τύπου (CEE) στεγανός 3P+N+E, 16 A, 400 V, IP44', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31224100-0', 'ΕΛΟΤ ΕΝ 60309-2', NULL, false, NULL, 9.5, 133),
  ('electrical', 'ELR-2026-134', 'Ρευματοδότης βιομηχανικού τύπου (CEE) 3P+N+E, 32 A, 400 V, IP67', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31224100-0', 'ΕΛΟΤ ΕΝ 60309-2', NULL, false, NULL, 14, 134),
  ('electrical', 'ELR-2026-135', 'Ρευματολήπτης (φις) βιομηχανικού τύπου (CEE) 3P+N+E, 16 A, 400 V', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31224100-0', 'ΕΛΟΤ ΕΝ 60309-2', NULL, false, NULL, 8, 135),
  ('electrical', 'ELR-2026-136', 'Ρευματολήπτης (φις) σούκο 2P+E, 16 A, αποσπώμενος', NULL, 'ΟΜΑΔΑ Η — ΔΙΑΚΟΠΤΙΚΟ ΥΛΙΚΟ & ΡΕΥΜΑΤΟΔΟΤΕΣ', 'τεμ', '31224100-0', 'ΕΛΟΤ ΕΝ 60884-1', NULL, false, NULL, 2.5, 136),
  ('electrical', 'ELR-2026-137', 'Λυχνία LED τύπου T8, μήκους 0,60 m, ισχύος 9 W, 4000 K (αντικ/ση λαμπτήρα φθορισμού 18 W)', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62776 / ΕΝ 62560', NULL, true, NULL, 3.5, 137),
  ('electrical', 'ELR-2026-138', 'Λυχνία LED τύπου T8, μήκους 0,60 m, ισχύος 9 W, 6500 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62776 / ΕΝ 62560', NULL, true, NULL, 3.5, 138),
  ('electrical', 'ELR-2026-139', 'Λυχνία LED τύπου T8, μήκους 1,20 m, ισχύος 18 W, 4000 K (αντικ/ση φθορισμού 36 W)', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62776 / ΕΝ 62560', NULL, true, NULL, 5, 139),
  ('electrical', 'ELR-2026-140', 'Λυχνία LED τύπου T8, μήκους 1,20 m, ισχύος 18 W, 6500 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62776 / ΕΝ 62560', NULL, true, NULL, 5, 140),
  ('electrical', 'ELR-2026-141', 'Λυχνία LED τύπου T8, μήκους 1,50 m, ισχύος 24 W, 4000 K (αντικ/ση φθορισμού 58 W)', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62776 / ΕΝ 62560', NULL, true, NULL, 7.5, 141),
  ('electrical', 'ELR-2026-142', 'Λυχνία LED τύπου T8, μήκους 1,50 m, ισχύος 24 W, 6500 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62776 / ΕΝ 62560', NULL, true, NULL, 7.5, 142),
  ('electrical', 'ELR-2026-143', 'Λαμπτήρας LED κοινός (A60) E27, 9 W, 4000 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62560 / ΕΝ 62612', NULL, true, NULL, 2.2, 143),
  ('electrical', 'ELR-2026-144', 'Λαμπτήρας LED κοινός (A60) E27, 13 W, 6500 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62560 / ΕΝ 62612', NULL, true, NULL, 2.8, 144),
  ('electrical', 'ELR-2026-145', 'Λαμπτήρας LED κηροειδής (C37) E14, 6 W', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62560 / ΕΝ 62612', NULL, true, NULL, 2.3, 145),
  ('electrical', 'ELR-2026-146', 'Λαμπτήρας LED κατευθυντικός (σποτ) GU10, 6 W, 4000 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62560 / ΕΝ 62612', NULL, true, NULL, 2.6, 146),
  ('electrical', 'ELR-2026-147', 'Λαμπτήρας LED υψηλής ισχύος (κορυφής) E27, 20 W, 6500 K', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62560 / ΕΝ 62612', NULL, true, NULL, 5.5, 147),
  ('electrical', 'ELR-2026-148', 'Λαμπτήρας LED υψηλής ισχύος E40, 50 W, 6500 K (αντικ/ση λαμπτήρα εκκένωσης HID)', NULL, 'ΟΜΑΔΑ Θ — ΦΩΤΙΣΜΟΣ LED: ΛΑΜΠΤΗΡΕΣ & ΛΥΧΝΙΕΣ (ΣΥΜΠ. ΑΝΤΙΚΑΤΑΣΤΑΣΗΣ ΦΘΟΡΙΣΜΟΥ T8)', 'τεμ', '31531000-7', 'ΕΛΟΤ ΕΝ 62560 / ΕΝ 62612', NULL, true, NULL, 22, 148),
  ('electrical', 'ELR-2026-149', 'Φωτιστικό σώμα στεγανό σκαφοειδές IP65 για 1×T8 1,20 m (χωρίς λυχνία)', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31520000-7', 'ΕΛΟΤ ΕΝ 60598-1', NULL, true, NULL, 9, 149),
  ('electrical', 'ELR-2026-150', 'Φωτιστικό σώμα στεγανό σκαφοειδές IP65 για 2×T8 1,20 m (χωρίς λυχνία)', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31520000-7', 'ΕΛΟΤ ΕΝ 60598-1', NULL, true, NULL, 12, 150),
  ('electrical', 'ELR-2026-151', 'Φωτιστικό σώμα LED στεγανό ολοκληρωμένο IP65, 1,20 m, 36 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31520000-7', 'ΕΛΟΤ ΕΝ 60598-1', NULL, true, NULL, 18, 151),
  ('electrical', 'ELR-2026-152', 'Φωτιστικό σώμα LED στεγανό ολοκληρωμένο IP65, 1,50 m, 50 W', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31520000-7', 'ΕΛΟΤ ΕΝ 60598-1', NULL, true, NULL, 26, 152),
  ('electrical', 'ELR-2026-153', 'Φωτιστικό LED ψευδοροφής (πάνελ) 600×600 mm, 36 W, 4000 K, UGR<19', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31520000-7', 'ΕΛΟΤ ΕΝ 60598-2-2', NULL, true, NULL, 16, 153),
  ('electrical', 'ELR-2026-154', 'Φωτιστικό LED χωνευτό (downlight) Φ170 mm, 18 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31520000-7', 'ΕΛΟΤ ΕΝ 60598-2-2', NULL, true, NULL, 7.5, 154),
  ('electrical', 'ELR-2026-155', 'Προβολέας LED εξωτερικού χώρου IP66, 30 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31518600-6', 'ΕΛΟΤ ΕΝ 60598-2-5', NULL, true, NULL, 12, 155),
  ('electrical', 'ELR-2026-156', 'Προβολέας LED IP66, 50 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31518600-6', 'ΕΛΟΤ ΕΝ 60598-2-5', NULL, true, NULL, 18, 156),
  ('electrical', 'ELR-2026-157', 'Προβολέας LED IP66, 100 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31518600-6', 'ΕΛΟΤ ΕΝ 60598-2-5', NULL, true, NULL, 32, 157),
  ('electrical', 'ELR-2026-158', 'Προβολέας LED IP66, 150 W, 5000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31518600-6', 'ΕΛΟΤ ΕΝ 60598-2-5', NULL, true, NULL, 48, 158),
  ('electrical', 'ELR-2026-159', 'Προβολέας LED IP66, 200 W, 5000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31518600-6', 'ΕΛΟΤ ΕΝ 60598-2-5', NULL, true, NULL, 68, 159),
  ('electrical', 'ELR-2026-160', 'Φωτιστικό σώμα οδοφωτισμού LED (επί βραχίονα), IP66, 60 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '34928500-3', 'ΕΛΟΤ ΕΝ 60598-2-3', NULL, true, NULL, 95, 160),
  ('electrical', 'ELR-2026-161', 'Φωτιστικό σώμα οδοφωτισμού LED IP66, 120 W, 4000 K', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '34928500-3', 'ΕΛΟΤ ΕΝ 60598-2-3', NULL, true, NULL, 165, 161),
  ('electrical', 'ELR-2026-162', 'Φωτιστικό ασφαλείας (φωτισμός εκτάκτου ανάγκης) LED, αυτόνομο, 3 W, 3 h', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31518200-2', 'ΕΛΟΤ ΕΝ 60598-2-22', NULL, true, NULL, 18, 162),
  ('electrical', 'ELR-2026-163', 'Τροφοδοτικό LED σταθεροποιημένο 24 V DC, 100 W, IP67', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΙΣΜΟΣ LED: ΦΩΤΙΣΤΙΚΑ ΣΩΜΑΤΑ', 'τεμ', '31200000-8', 'ΕΛΟΤ ΕΝ 61347-2-13', NULL, false, NULL, 24, 163),
  ('electrical', 'ELR-2026-164', 'Εύκαμπτος κυματοειδής σωλήνας PVC (σπιράλ) βαρέως τύπου Φ16 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-22 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 0.35, 164),
  ('electrical', 'ELR-2026-165', 'Εύκαμπτος κυματοειδής σωλήνας PVC (σπιράλ) Φ23 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-22 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 0.55, 165),
  ('electrical', 'ELR-2026-166', 'Εύκαμπτος κυματοειδής σωλήνας PVC (σπιράλ) Φ32 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-22 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 0.85, 166),
  ('electrical', 'ELR-2026-167', 'Εύκαμπτος κυματοειδής σωλήνας PVC (σπιράλ) Φ40 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-22 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 1.2, 167),
  ('electrical', 'ELR-2026-168', 'Άκαμπτος (ευθύς) πλαστικός σωλήνας PVC Φ16 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-21 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 0.45, 168),
  ('electrical', 'ELR-2026-169', 'Άκαμπτος (ευθύς) πλαστικός σωλήνας PVC Φ25 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-21 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 0.7, 169),
  ('electrical', 'ELR-2026-170', 'Άκαμπτος (ευθύς) πλαστικός σωλήνας PVC Φ32 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-21 / ΕΤΕΠ 04-20-01-02', NULL, true, NULL, 0.95, 170),
  ('electrical', 'ELR-2026-171', 'Σωλήνας υπογείων καλωδίων δομημένου τοιχώματος (HDPE) Φ50 mm, κόκκινος', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-24', NULL, true, NULL, 1.3, 171),
  ('electrical', 'ELR-2026-172', 'Σωλήνας δομημένου τοιχώματος (HDPE) Φ63 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-24', NULL, true, NULL, 1.7, 172),
  ('electrical', 'ELR-2026-173', 'Σωλήνας δομημένου τοιχώματος (HDPE) Φ90 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-24', NULL, true, NULL, 2.8, 173),
  ('electrical', 'ELR-2026-174', 'Σωλήνας δομημένου τοιχώματος (HDPE) Φ110 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-24', NULL, true, NULL, 3.6, 174),
  ('electrical', 'ELR-2026-175', 'Σωλήνας δομημένου τοιχώματος (HDPE) Φ160 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322100-4', 'ΕΛΟΤ ΕΝ 61386-24', NULL, true, NULL, 6.5, 175),
  ('electrical', 'ELR-2026-176', 'Πλαστικό κανάλι διανομής (μη διάτρητο) 40×40 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322300-6', 'ΕΛΟΤ ΕΝ 50085 / ΕΤΕΠ 04-20-01-06', NULL, false, NULL, 2.8, 176),
  ('electrical', 'ELR-2026-177', 'Πλαστικό κανάλι διανομής 60×40 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322300-6', 'ΕΛΟΤ ΕΝ 50085 / ΕΤΕΠ 04-20-01-06', NULL, false, NULL, 3.6, 177),
  ('electrical', 'ELR-2026-178', 'Πλαστικό κανάλι διανομής 100×60 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322300-6', 'ΕΛΟΤ ΕΝ 50085 / ΕΤΕΠ 04-20-01-06', NULL, false, NULL, 5.8, 178),
  ('electrical', 'ELR-2026-179', 'Εσχάρα καλωδίων γαλβανισμένη εν θερμώ, διάτρητη, πλάτους 100 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322300-6', 'ΕΛΟΤ ΕΝ 61537 / ΕΤΕΠ 04-20-01-03', NULL, false, NULL, 8.5, 179),
  ('electrical', 'ELR-2026-180', 'Εσχάρα καλωδίων γαλβανισμένη, διάτρητη, πλάτους 200 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322300-6', 'ΕΛΟΤ ΕΝ 61537 / ΕΤΕΠ 04-20-01-03', NULL, false, NULL, 12, 180),
  ('electrical', 'ELR-2026-181', 'Εσχάρα καλωδίων γαλβανισμένη, διάτρητη, πλάτους 300 mm', NULL, 'ΟΜΑΔΑ Κ — ΣΩΛΗΝΩΣΕΙΣ & ΣΥΣΤΗΜΑΤΑ ΟΔΕΥΣΗΣ ΚΑΛΩΔΙΩΝ', 'm', '44322300-6', 'ΕΛΟΤ ΕΝ 61537 / ΕΤΕΠ 04-20-01-03', NULL, false, NULL, 16, 181),
  ('electrical', 'ELR-2026-182', 'Κουτί εντοιχιζόμενο πλαστικό, στρογγυλό Φ65 mm (διακόπτη/ρευματοδότη)', NULL, 'ΟΜΑΔΑ Λ — ΚΟΥΤΙΑ ΔΙΑΚΛΑΔΩΣΗΣ & ΕΓΚΑΤΑΣΤΑΣΗΣ', 'τεμ', '31224700-8', 'ΕΛΟΤ ΕΝ 60670-1', NULL, true, NULL, 0.4, 182),
  ('electrical', 'ELR-2026-183', 'Κουτί διακλάδωσης εντοιχιζόμενο τετράγωνο 100×100 mm, με κάλυμμα', NULL, 'ΟΜΑΔΑ Λ — ΚΟΥΤΙΑ ΔΙΑΚΛΑΔΩΣΗΣ & ΕΓΚΑΤΑΣΤΑΣΗΣ', 'τεμ', '31224700-8', 'ΕΛΟΤ ΕΝ 60670-1', NULL, true, NULL, 0.9, 183),
  ('electrical', 'ELR-2026-184', 'Κουτί διακλάδωσης επιφανειακό στεγανό IP55, 100×100×50 mm', NULL, 'ΟΜΑΔΑ Λ — ΚΟΥΤΙΑ ΔΙΑΚΛΑΔΩΣΗΣ & ΕΓΚΑΤΑΣΤΑΣΗΣ', 'τεμ', '31224700-8', 'ΕΛΟΤ ΕΝ 60670-22', NULL, true, NULL, 2.2, 184),
  ('electrical', 'ELR-2026-185', 'Κουτί διακλάδωσης επιφανειακό στεγανό IP55, 150×110×70 mm', NULL, 'ΟΜΑΔΑ Λ — ΚΟΥΤΙΑ ΔΙΑΚΛΑΔΩΣΗΣ & ΕΓΚΑΤΑΣΤΑΣΗΣ', 'τεμ', '31224700-8', 'ΕΛΟΤ ΕΝ 60670-22', NULL, true, NULL, 3.5, 185),
  ('electrical', 'ELR-2026-186', 'Κουτί διακλάδωσης επιφανειακό στεγανό IP65, 200×150×80 mm', NULL, 'ΟΜΑΔΑ Λ — ΚΟΥΤΙΑ ΔΙΑΚΛΑΔΩΣΗΣ & ΕΓΚΑΤΑΣΤΑΣΗΣ', 'τεμ', '31224700-8', 'ΕΛΟΤ ΕΝ 60670-22', NULL, true, NULL, 6.5, 186),
  ('electrical', 'ELR-2026-187', 'Συστοιχία ακροδεκτών (κλεμοσειρά) πολυαμιδίου 12 θέσεων, 2,5 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60998-2-1', NULL, true, NULL, 0.35, 187),
  ('electrical', 'ELR-2026-188', 'Συστοιχία ακροδεκτών (κλεμοσειρά) 12 θέσεων, 4 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60998-2-1', NULL, true, NULL, 0.45, 188),
  ('electrical', 'ELR-2026-189', 'Συστοιχία ακροδεκτών (κλεμοσειρά) 12 θέσεων, 6 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60998-2-1', NULL, true, NULL, 0.6, 189),
  ('electrical', 'ELR-2026-190', 'Συστοιχία ακροδεκτών (κλεμοσειρά) 12 θέσεων, 10 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60998-2-1', NULL, true, NULL, 0.95, 190),
  ('electrical', 'ELR-2026-191', 'Συστοιχία ακροδεκτών (κλεμοσειρά) 12 θέσεων, 16 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60998-2-1', NULL, true, NULL, 1.4, 191),
  ('electrical', 'ELR-2026-192', 'Ακροδέκτης σύνδεσης ράγας, βιδωτός, 4 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60947-7-1', NULL, false, NULL, 0.55, 192),
  ('electrical', 'ELR-2026-193', 'Ακροδέκτης σύνδεσης ράγας, βιδωτός, 6 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60947-7-1', NULL, false, NULL, 0.75, 193),
  ('electrical', 'ELR-2026-194', 'Ακροδέκτης σύνδεσης ράγας, βιδωτός, 10 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60947-7-1', NULL, false, NULL, 1.1, 194),
  ('electrical', 'ELR-2026-195', 'Ακροδέκτης σύνδεσης ράγας γείωσης, 4 mm² (κιτρινοπράσινος)', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 60947-7-2', NULL, false, NULL, 1.3, 195),
  ('electrical', 'ELR-2026-196', 'Σύνδεσμος ταχείας σύνδεσης αγωγών 3 θέσεων (push-in)', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ IEC 60998-2-2', NULL, true, NULL, 0.3, 196),
  ('electrical', 'ELR-2026-197', 'Σύνδεσμος ταχείας σύνδεσης αγωγών 5 θέσεων (push-in)', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ IEC 60998-2-2', NULL, true, NULL, 0.45, 197),
  ('electrical', 'ELR-2026-198', 'Ακροχιτώνιο (μύτη) αγωγού μονωμένο 1,5 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'DIN 46228-4', NULL, false, NULL, 0.03, 198),
  ('electrical', 'ELR-2026-199', 'Ακροχιτώνιο αγωγού μονωμένο 2,5 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'DIN 46228-4', NULL, false, NULL, 0.03, 199),
  ('electrical', 'ELR-2026-200', 'Ακροχιτώνιο αγωγού μονωμένο 4 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'DIN 46228-4', NULL, false, NULL, 0.04, 200),
  ('electrical', 'ELR-2026-201', 'Ακροχιτώνιο αγωγού μονωμένο 6 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'DIN 46228-4', NULL, false, NULL, 0.05, 201),
  ('electrical', 'ELR-2026-202', 'Ακροχιτώνιο αγωγού μονωμένο 10 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'DIN 46228-4', NULL, false, NULL, 0.08, 202),
  ('electrical', 'ELR-2026-203', 'Ακροδέκτης δακτυλίου (πέδιλο) χάλκινος επικασσιτερωμένος 6 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 61238-1', NULL, false, NULL, 0.15, 203),
  ('electrical', 'ELR-2026-204', 'Ακροδέκτης δακτυλίου (πέδιλο) 10 mm²', NULL, 'ΟΜΑΔΑ Μ — ΑΚΡΟΔΕΚΤΕΣ, ΚΛΕΜΜΕΣ & ΥΛΙΚΑ ΣΥΝΔΕΣΗΣ', 'τεμ', '31224000-9', 'ΕΛΟΤ ΕΝ 61238-1', NULL, false, NULL, 0.22, 204),
  ('electrical', 'ELR-2026-205', 'Ταινία πρόσδεσης καλωδίων (δεματικό) πολυαμιδίου 2,5×100 mm, λευκό', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.01, 205),
  ('electrical', 'ELR-2026-206', 'Ταινία πρόσδεσης (δεματικό) 2,5×160 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.01, 206),
  ('electrical', 'ELR-2026-207', 'Ταινία πρόσδεσης (δεματικό) 3,6×200 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.02, 207),
  ('electrical', 'ELR-2026-208', 'Ταινία πρόσδεσης (δεματικό) 3,6×290 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.03, 208),
  ('electrical', 'ELR-2026-209', 'Ταινία πρόσδεσης (δεματικό) 4,8×300 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.03, 209),
  ('electrical', 'ELR-2026-210', 'Ταινία πρόσδεσης (δεματικό) 4,8×370 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.04, 210),
  ('electrical', 'ELR-2026-211', 'Ταινία πρόσδεσης (δεματικό) 4,8×430 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.05, 211),
  ('electrical', 'ELR-2026-212', 'Ταινία πρόσδεσης (δεματικό) 7,6×540 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.09, 212),
  ('electrical', 'ELR-2026-213', 'Ταινία πρόσδεσης (δεματικό) 7,6×750 mm (μήκος ≥ 70 cm)', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.15, 213),
  ('electrical', 'ELR-2026-214', 'Ταινία πρόσδεσης (δεματικό) 9,0×920 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.25, 214),
  ('electrical', 'ELR-2026-215', 'Ταινία πρόσδεσης (δεματικό) ανθεκτικό σε UV (μαύρο) 4,8×300 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.04, 215),
  ('electrical', 'ELR-2026-216', 'Ταινία πρόσδεσης (δεματικό) UV (μαύρο) 7,6×540 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.1, 216),
  ('electrical', 'ELR-2026-217', 'Ταινία πρόσδεσης (δεματικό) UV (μαύρο) 9,0×780 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.2, 217),
  ('electrical', 'ELR-2026-218', 'Στήριγμα (κλιπ) σωλήνα Φ16 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.05, 218),
  ('electrical', 'ELR-2026-219', 'Στήριγμα (κλιπ) σωλήνα Φ32 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.08, 219),
  ('electrical', 'ELR-2026-220', 'Πλαστικό βύσμα στερέωσης τοίχου Φ6 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '31680000-6', '—', NULL, false, NULL, 0.02, 220),
  ('electrical', 'ELR-2026-221', 'Πλαστικό βύσμα στερέωσης τοίχου Φ10 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '31680000-6', '—', NULL, false, NULL, 0.04, 221),
  ('electrical', 'ELR-2026-222', 'Μονωτική ταινία PVC 19 mm × 20 m (μαύρη)', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '31680000-6', 'ΕΛΟΤ ΕΝ 60454-3-1', NULL, false, NULL, 0.55, 222),
  ('electrical', 'ELR-2026-223', 'Αυτοβουλκανιζόμενη ταινία στεγανοποίησης 19 mm × 10 m', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '31680000-6', 'ΕΛΟΤ ΕΝ 60454', NULL, false, NULL, 4.5, 223),
  ('electrical', 'ELR-2026-224', 'Σφιγκτήρας μεταλλικός καλωδίων (κολάρο) με βύσμα, Φ16–20 mm', NULL, 'ΟΜΑΔΑ Ν — ΥΛΙΚΑ ΠΡΟΣΔΕΣΗΣ, ΣΤΗΡΙΞΗΣ & ΜΟΝΩΣΗΣ', 'τεμ', '44322400-7', '—', NULL, false, NULL, 0.12, 224),
  ('electrical', 'ELR-2026-225', 'Γυμνός χάλκινος πολύκλωνος αγωγός γείωσης 16 mm²', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 60228 / ΕΤΕΠ 04-50-02-00', NULL, false, NULL, 2.8, 225),
  ('electrical', 'ELR-2026-226', 'Γυμνός χάλκινος αγωγός γείωσης 25 mm²', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 60228 / ΕΤΕΠ 04-50-02-00', NULL, false, NULL, 4.3, 226),
  ('electrical', 'ELR-2026-227', 'Γυμνός χάλκινος αγωγός γείωσης 35 mm²', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 60228 / ΕΤΕΠ 04-50-02-00', NULL, false, NULL, 6, 227),
  ('electrical', 'ELR-2026-228', 'Αγωγός γείωσης μονωμένος H07V-K κιτρινοπράσινος 16 mm²', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'm', '31300000-9', 'ΕΛΟΤ ΕΝ 50525-2-31', NULL, true, NULL, 3.1, 228),
  ('electrical', 'ELR-2026-229', 'Ηλεκτρόδιο γείωσης (ράβδος) επιχαλκωμένο Φ14,2 mm × 1,5 m', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'τεμ', '31600000-2', 'ΕΛΟΤ ΕΝ 62561-2', NULL, false, NULL, 12, 229),
  ('electrical', 'ELR-2026-230', 'Σφιγκτήρας σύνδεσης ηλεκτροδίου γείωσης, ορειχάλκινος', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'τεμ', '31600000-2', 'ΕΛΟΤ ΕΝ 62561-1', NULL, false, NULL, 3.5, 230),
  ('electrical', 'ELR-2026-231', 'Ζυγός ισοδυναμικών συνδέσεων (μπάρα γείωσης) με κάλυμμα', NULL, 'ΟΜΑΔΑ Ξ — ΓΕΙΩΣΗ & ΑΝΤΙΚΕΡΑΥΝΙΚΗ ΠΡΟΣΤΑΣΙΑ', 'τεμ', '31600000-2', 'ΕΛΟΤ ΕΝ 62561-1', NULL, false, NULL, 14, 231),
  ('building', 'BLD-2026-009', 'Τσιμέντο Portland σύνθετο CEM II/B-M 32,5 N, σάκος 25 kg', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 'τεμ', '44111200-3', 'ΕΛΟΤ ΕΝ 197-1', NULL, true, NULL, 4.5, 9),
  ('building', 'BLD-2026-010', 'Τσιμέντο Portland CEM II/A 42,5 N, σάκος 25 kg', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 'τεμ', '44111200-3', 'ΕΛΟΤ ΕΝ 197-1', NULL, true, NULL, 5.2, 10),
  ('building', 'BLD-2026-011', 'Τσιμέντο χύδην CEM II 32,5, ανά τόνο', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 't', '44111200-3', 'ΕΛΟΤ ΕΝ 197-1', NULL, true, NULL, 110, 11),
  ('building', 'BLD-2026-012', 'Λευκό τσιμέντο, σάκος 25 kg', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 'τεμ', '44111200-3', 'ΕΛΟΤ ΕΝ 197-1', NULL, true, NULL, 9.5, 12),
  ('building', 'BLD-2026-013', 'Υδράσβεστος (σβησμένος ασβέστης) σε σκόνη, σάκος 20 kg', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 'τεμ', '44921210-7', 'ΕΛΟΤ ΕΝ 459-1', NULL, true, NULL, 4, 13),
  ('building', 'BLD-2026-014', 'Ασβεστοπολτός (σβησμένος ασβέστης σε πάστα), ανά m³', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 'm³', '44921200-4', 'ΕΛΟΤ ΕΝ 459-1', NULL, true, NULL, 95, 14),
  ('building', 'BLD-2026-015', 'Δομικός γύψος (κονία επιχρισμάτων), σάκος 25 kg', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 'τεμ', '44921100-3', 'ΕΛΟΤ ΕΝ 13279-1', NULL, false, NULL, 6, 15),
  ('building', 'BLD-2026-016', 'Φυσική ποζολάνη (θηραϊκή γη), ανά τόνο', NULL, 'ΟΜΑΔΑ Β — ΤΣΙΜΕΝΤΟ, ΑΣΒΕΣΤΗΣ & ΚΟΝΙΕΣ', 't', '44921300-5', 'ΕΛΟΤ ΕΝ 197-1', NULL, true, NULL, 45, 16),
  ('building', 'BLD-2026-017', 'Σκυρόδεμα κατηγορίας C12/15 (στρώση καθαριότητας)', NULL, 'ΟΜΑΔΑ Γ — ΕΤΟΙΜΟ ΣΚΥΡΟΔΕΜΑ (ΕΡΓΟΣΤΑΣΙΑΚΟ)', 'm³', '44114100-3', 'ΕΛΟΤ ΕΝ 206 / ΚΤΣ-2016 / ΕΤΕΠ 01-01-01-00', NULL, false, NULL, 78, 17),
  ('building', 'BLD-2026-018', 'Σκυρόδεμα κατηγορίας C16/20', NULL, 'ΟΜΑΔΑ Γ — ΕΤΟΙΜΟ ΣΚΥΡΟΔΕΜΑ (ΕΡΓΟΣΤΑΣΙΑΚΟ)', 'm³', '44114100-3', 'ΕΛΟΤ ΕΝ 206 / ΚΤΣ-2016 / ΕΤΕΠ 01-01-01-00', NULL, false, NULL, 82, 18),
  ('building', 'BLD-2026-019', 'Σκυρόδεμα κατηγορίας C20/25', NULL, 'ΟΜΑΔΑ Γ — ΕΤΟΙΜΟ ΣΚΥΡΟΔΕΜΑ (ΕΡΓΟΣΤΑΣΙΑΚΟ)', 'm³', '44114100-3', 'ΕΛΟΤ ΕΝ 206 / ΚΤΣ-2016 / ΕΤΕΠ 01-01-01-00', NULL, false, NULL, 88, 19),
  ('building', 'BLD-2026-020', 'Σκυρόδεμα κατηγορίας C25/30', NULL, 'ΟΜΑΔΑ Γ — ΕΤΟΙΜΟ ΣΚΥΡΟΔΕΜΑ (ΕΡΓΟΣΤΑΣΙΑΚΟ)', 'm³', '44114100-3', 'ΕΛΟΤ ΕΝ 206 / ΚΤΣ-2016 / ΕΤΕΠ 01-01-01-00', NULL, false, NULL, 94, 20),
  ('building', 'BLD-2026-021', 'Σκυρόδεμα κατηγορίας C30/37', NULL, 'ΟΜΑΔΑ Γ — ΕΤΟΙΜΟ ΣΚΥΡΟΔΕΜΑ (ΕΡΓΟΣΤΑΣΙΑΚΟ)', 'm³', '44114100-3', 'ΕΛΟΤ ΕΝ 206 / ΚΤΣ-2016 / ΕΤΕΠ 01-01-01-00', NULL, false, NULL, 102, 21),
  ('building', 'BLD-2026-022', 'Ελαφροσκυρόδεμα κλίσεων (κισηρόδεμα)', NULL, 'ΟΜΑΔΑ Γ — ΕΤΟΙΜΟ ΣΚΥΡΟΔΕΜΑ (ΕΡΓΟΣΤΑΣΙΑΚΟ)', 'm³', '44114100-3', 'ΕΛΟΤ ΕΝ 206', NULL, false, NULL, 75, 22),
  ('building', 'BLD-2026-023', 'Χάλυβας οπλισμού σκυροδέματος B500C, ράβδοι Φ8 mm', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44331000-9', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3 / ΕΤΕΠ 01-02-01-00', NULL, true, NULL, 1.05, 23),
  ('building', 'BLD-2026-024', 'Χάλυβας οπλισμού B500C, ράβδοι Φ10 mm', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44331000-9', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3', NULL, true, NULL, 1.02, 24),
  ('building', 'BLD-2026-025', 'Χάλυβας οπλισμού B500C, ράβδοι Φ12 mm', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44331000-9', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3', NULL, true, NULL, 1, 25),
  ('building', 'BLD-2026-026', 'Χάλυβας οπλισμού B500C, ράβδοι Φ14 mm', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44331000-9', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3', NULL, true, NULL, 1, 26),
  ('building', 'BLD-2026-027', 'Χάλυβας οπλισμού B500C, ράβδοι Φ16 mm', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44331000-9', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3', NULL, true, NULL, 0.98, 27),
  ('building', 'BLD-2026-028', 'Χάλυβας οπλισμού B500C, ράβδοι Φ20 mm', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44331000-9', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3', NULL, true, NULL, 0.98, 28),
  ('building', 'BLD-2026-029', 'Δομικό πλέγμα ηλεκτροσυγκολλητό B500C (τύπου Τ131–Τ196)', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44333000-3', 'ΕΛΟΤ ΕΝ 10080 / ΕΛΟΤ 1421-3', NULL, true, NULL, 1.1, 29),
  ('building', 'BLD-2026-030', 'Σύρμα δεσίματος οπλισμού (μαλακό, ανοπτημένο)', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44333000-3', 'ΕΛΟΤ ΕΝ 10016', NULL, false, NULL, 1.8, 30),
  ('building', 'BLD-2026-031', 'Δομικός χάλυβας μορφοσίδηρος S235JR (IPE/HEA/UPN/γωνιακά)', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44212500-4', 'ΕΛΟΤ ΕΝ 10025-2', NULL, false, NULL, 1.4, 31),
  ('building', 'BLD-2026-032', 'Κοιλοδοκός / στραντζαριστή διατομή S235 (κοίλη)', NULL, 'ΟΜΑΔΑ Δ — ΧΑΛΥΒΑΣ ΟΠΛΙΣΜΟΥ & ΔΟΜΙΚΟΣ ΧΑΛΥΒΑΣ', 'kg', '44334000-0', 'ΕΛΟΤ ΕΝ 10219-1', NULL, false, NULL, 1.55, 32),
  ('building', 'BLD-2026-033', 'Οπτόπλινθος (διάτρητος) 6 οπών, 6×9×19 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111100-2', 'ΕΛΟΤ ΕΝ 771-1', NULL, true, NULL, 0.2, 33),
  ('building', 'BLD-2026-034', 'Οπτόπλινθος (διάτρητος) 9 οπών, 9×12×19 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111100-2', 'ΕΛΟΤ ΕΝ 771-1', NULL, true, NULL, 0.28, 34),
  ('building', 'BLD-2026-035', 'Οπτόπλινθος (διάτρητος) 12 οπών, 12×19×24 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111100-2', 'ΕΛΟΤ ΕΝ 771-1', NULL, true, NULL, 0.45, 35),
  ('building', 'BLD-2026-036', 'Πλινθόλιθος συμπαγής (μπατικός)', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111100-2', 'ΕΛΟΤ ΕΝ 771-1', NULL, true, NULL, 0.35, 36),
  ('building', 'BLD-2026-037', 'Δομικό στοιχείο σκυροδέματος (τσιμεντόλιθος) 10×20×40 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111600-7', 'ΕΛΟΤ ΕΝ 771-3', NULL, true, NULL, 0.55, 37),
  ('building', 'BLD-2026-038', 'Δομικό στοιχείο σκυροδέματος (τσιμεντόλιθος) 15×20×40 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111600-7', 'ΕΛΟΤ ΕΝ 771-3', NULL, true, NULL, 0.7, 38),
  ('building', 'BLD-2026-039', 'Δομικό στοιχείο σκυροδέματος (τσιμεντόλιθος) 20×20×40 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111600-7', 'ΕΛΟΤ ΕΝ 771-3', NULL, true, NULL, 0.85, 39),
  ('building', 'BLD-2026-040', 'Στοιχείο τοιχοποιίας αυτόκλειστου αεριζομένου σκυροδέματος (πορομπετόν) 10×25×60 cm', NULL, 'ΟΜΑΔΑ Ε — ΥΛΙΚΑ ΤΟΙΧΟΠΟΙΙΑΣ', 'τεμ', '44111600-7', 'ΕΛΟΤ ΕΝ 771-4', NULL, true, NULL, 1.3, 40),
  ('building', 'BLD-2026-041', 'Κονίαμα τοιχοποιίας έτοιμο (ξηρό), σάκος 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΚΟΝΙΑΜΑΤΑ & ΕΠΙΧΡΙΣΜΑΤΑ', 'τεμ', '44111800-9', 'ΕΛΟΤ ΕΝ 998-2', NULL, true, NULL, 3.5, 41),
  ('building', 'BLD-2026-042', 'Επίχρισμα βάσης (σοβάς) έτοιμο, σάκος 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΚΟΝΙΑΜΑΤΑ & ΕΠΙΧΡΙΣΜΑΤΑ', 'τεμ', '44111800-9', 'ΕΛΟΤ ΕΝ 998-1', NULL, true, NULL, 4, 42),
  ('building', 'BLD-2026-043', 'Επίχρισμα τελικής στρώσης λείο (μαρμαροκονία), σάκος 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΚΟΝΙΑΜΑΤΑ & ΕΠΙΧΡΙΣΜΑΤΑ', 'τεμ', '44111800-9', 'ΕΛΟΤ ΕΝ 998-1', NULL, true, NULL, 6.5, 43),
  ('building', 'BLD-2026-044', 'Επισκευαστικό μη συρρικνούμενο κονίαμα (grout), σάκος 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΚΟΝΙΑΜΑΤΑ & ΕΠΙΧΡΙΣΜΑΤΑ', 'τεμ', '44831400-8', 'ΕΛΟΤ ΕΝ 1504-3', NULL, true, NULL, 12, 44),
  ('building', 'BLD-2026-045', 'Χημικό πρόσμικτο σκυροδέματος ρευστοποιητικό/υπερρευστοποιητικό', NULL, 'ΟΜΑΔΑ ΣΤ — ΚΟΝΙΑΜΑΤΑ & ΕΠΙΧΡΙΣΜΑΤΑ', 'kg', '24957000-7', 'ΕΛΟΤ ΕΝ 934-2', NULL, true, NULL, 1.8, 45),
  ('building', 'BLD-2026-046', 'Πλάκες διογκωμένης πολυστερίνης (EPS) πάχους 50 mm', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'm²', '44111520-2', 'ΕΛΟΤ ΕΝ 13163', NULL, true, NULL, 3.5, 46),
  ('building', 'BLD-2026-047', 'Πλάκες εξηλασμένης πολυστερίνης (XPS) πάχους 50 mm', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'm²', '44111520-2', 'ΕΛΟΤ ΕΝ 13164', NULL, true, NULL, 6, 47),
  ('building', 'BLD-2026-048', 'Πλάκες ορυκτοβάμβακα (πετροβάμβακας) πάχους 50 mm', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'm²', '44111520-2', 'ΕΛΟΤ ΕΝ 13162', NULL, true, NULL, 5.5, 48),
  ('building', 'BLD-2026-049', 'Ασφαλτική μεμβράνη στεγάνωσης οπλισμένη 4 mm (με επικάλυψη ψηφίδας)', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'm²', '44112500-3', 'ΕΛΟΤ ΕΝ 13707', NULL, true, NULL, 4.5, 49),
  ('building', 'BLD-2026-050', 'Επαλειφόμενο στεγανωτικό κονίαμα 2 συστατικών, ανά kg', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'kg', '44831100-5', 'ΕΛΟΤ ΕΝ 14891', NULL, true, NULL, 3.2, 50),
  ('building', 'BLD-2026-051', 'Ασφαλτικό βερνίκι/γαλάκτωμα προεπάλειψης (primer), ανά kg', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'kg', '44113610-4', 'ΕΛΟΤ ΕΝ 15814', NULL, false, NULL, 2.5, 51),
  ('building', 'BLD-2026-052', 'Φράγμα υδρατμών πολυαιθυλενίου 200 μm', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'm²', '44176000-4', 'ΕΛΟΤ ΕΝ 13984', NULL, true, NULL, 0.6, 52),
  ('building', 'BLD-2026-053', 'Γεωύφασμα μη υφαντό 200 g/m² (διαχωρισμού/προστασίας)', NULL, 'ΟΜΑΔΑ Ζ — ΘΕΡΜΟ/ΗΧΟΜΟΝΩΣΗ & ΣΤΕΓΑΝΩΣΗ', 'm²', '44170000-2', 'ΕΛΟΤ ΕΝ 13252', NULL, false, NULL, 1.2, 53),
  ('building', 'BLD-2026-054', 'Πλακίδια δαπέδου εφυαλωμένα πορσελάνης (γρανίτη) 60×60 cm', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'm²', '44111900-0', 'ΕΛΟΤ ΕΝ 14411', NULL, true, NULL, 14, 54),
  ('building', 'BLD-2026-055', 'Πλακίδια επένδυσης τοίχου εφυαλωμένα 25×40 cm', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'm²', '44111700-8', 'ΕΛΟΤ ΕΝ 14411', NULL, true, NULL, 10, 55),
  ('building', 'BLD-2026-056', 'Συγκολλητικό κονίαμα πλακιδίων (τσιμεντοειδές, C2TE), σάκος 25 kg', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 12004', NULL, false, NULL, 8, 56),
  ('building', 'BLD-2026-057', 'Αρμόστοκος πλακιδίων (CG2), σάκος 5 kg', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'τεμ', '44831400-8', 'ΕΛΟΤ ΕΝ 13888', NULL, false, NULL, 6.5, 57),
  ('building', 'BLD-2026-058', 'Πλάκες μαρμάρου (λευκό/μπεζ) πάχους 2 cm', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'm²', '44911100-0', 'ΕΛΟΤ ΕΝ 12058', NULL, false, NULL, 45, 58),
  ('building', 'BLD-2026-059', 'Βιομηχανικό δάπεδο τσιμεντοκονίας (πατητή), ανά m²', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'm²', '44112200-0', 'ΕΛΟΤ ΕΝ 13813', NULL, true, NULL, 9, 59),
  ('building', 'BLD-2026-060', 'Αυτοεπιπεδούμενο τσιμεντοκονίαμα δαπέδων, σάκος 25 kg', NULL, 'ΟΜΑΔΑ Η — ΕΠΙΣΤΡΩΣΕΙΣ, ΕΠΕΝΔΥΣΕΙΣ & ΔΑΠΕΔΑ', 'τεμ', '44111800-9', 'ΕΛΟΤ ΕΝ 13813', NULL, true, NULL, 11, 60),
  ('building', 'BLD-2026-061', 'Γυψοσανίδα κοινή 12,5 mm (1,20×2,60 m)', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm²', '44190000-8', 'ΕΛΟΤ ΕΝ 520', NULL, true, NULL, 4.5, 61),
  ('building', 'BLD-2026-062', 'Γυψοσανίδα ανθυγρή 12,5 mm', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm²', '44190000-8', 'ΕΛΟΤ ΕΝ 520', NULL, true, NULL, 6.5, 62),
  ('building', 'BLD-2026-063', 'Γυψοσανίδα πυράντοχη 12,5 mm', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm²', '44190000-8', 'ΕΛΟΤ ΕΝ 520', NULL, true, NULL, 6, 63),
  ('building', 'BLD-2026-064', 'Τσιμεντοσανίδα 12,5 mm', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm²', '44190000-8', 'ΕΛΟΤ ΕΝ 12467', NULL, false, NULL, 12, 64),
  ('building', 'BLD-2026-065', 'Στραντζαριστός ορθοστάτης γαλβανισμένος (50/75/100 mm)', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm', '44334000-0', 'ΕΛΟΤ ΕΝ 14195', NULL, true, NULL, 1.8, 65),
  ('building', 'BLD-2026-066', 'Στραντζαριστός στρωτήρας/οδηγός γαλβανισμένος', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm', '44334000-0', 'ΕΛΟΤ ΕΝ 14195', NULL, true, NULL, 1.7, 66),
  ('building', 'BLD-2026-067', 'Στόκος αρμολόγησης γυψοσανίδων, σάκος 20 kg', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'τεμ', '44831200-6', 'ΕΛΟΤ ΕΝ 13963', NULL, true, NULL, 14, 67),
  ('building', 'BLD-2026-068', 'Ταινία οπλισμού αρμών γυψοσανίδων (υαλόπλεγμα/χάρτινη)', NULL, 'ΟΜΑΔΑ Θ — ΓΥΨΟΣΑΝΙΔΕΣ & ΣΥΣΤΗΜΑΤΑ ΞΗΡΑΣ ΔΟΜΗΣΗΣ', 'm', '44424200-0', 'ΕΛΟΤ ΕΝ 13963', NULL, true, NULL, 0.1, 68),
  ('building', 'BLD-2026-069', 'Πλαστικό χρώμα εσωτερικών χώρων (λευκό), δοχείο 9 L', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 28, 69),
  ('building', 'BLD-2026-070', 'Ακρυλικό χρώμα εξωτερικών χώρων (100% ακρυλικό), δοχείο 9 L', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 45, 70),
  ('building', 'BLD-2026-071', 'Αστάρι ακρυλικό μικρομοριακό διαλύτου, δοχείο 5 L', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 32, 71),
  ('building', 'BLD-2026-072', 'Υδρόχρωμα κοινό (λευκό), δοχείο 10 kg', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 12, 72),
  ('building', 'BLD-2026-073', 'Βερνικόχρωμα (ριπολίνη) διαλύτου, δοχείο 2,5 L', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44812210-0', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 22, 73),
  ('building', 'BLD-2026-074', 'Σπατουλαριστός στόκος γενικής χρήσης, δοχείο 5 kg', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44831200-6', 'ΕΛΟΤ ΕΝ 998-1', NULL, true, NULL, 14, 74),
  ('building', 'BLD-2026-075', 'Μυκητοκτόνο διάλυμα επιφανειών, δοχείο 1 L', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44832000-1', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 8, 75),
  ('building', 'BLD-2026-076', 'Διαλυτικό (white spirit/νέφτι), δοχείο 4 L', NULL, 'ΟΜΑΔΑ Ι — ΧΡΩΜΑΤΙΣΜΟΙ & ΣΥΝΑΦΗ', 'τεμ', '44832200-3', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 9, 76),
  ('building', 'BLD-2026-077', 'Πριστή δομική ξυλεία (καδρόνια) ψυχρών κλιμάτων, ανά m³', NULL, 'ΟΜΑΔΑ Κ — ΞΥΛΕΙΑ & ΣΥΝΘΕΤΑ ΞΥΛΟΥ', 'm³', '44191000-5', 'ΕΛΟΤ ΕΝ 14081-1', NULL, true, NULL, 320, 77),
  ('building', 'BLD-2026-078', 'Αντικολλητή ξυλεία (κόντρα πλακέ) θαλάσσης 18 mm', NULL, 'ΟΜΑΔΑ Κ — ΞΥΛΕΙΑ & ΣΥΝΘΕΤΑ ΞΥΛΟΥ', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636', NULL, true, NULL, 22, 78),
  ('building', 'BLD-2026-079', 'Μοριοσανίδα 18 mm', NULL, 'ΟΜΑΔΑ Κ — ΞΥΛΕΙΑ & ΣΥΝΘΕΤΑ ΞΥΛΟΥ', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 312', NULL, true, NULL, 9, 79),
  ('building', 'BLD-2026-080', 'Πλάκα προσανατολισμένων ινών (OSB/3) 15 mm', NULL, 'ΟΜΑΔΑ Κ — ΞΥΛΕΙΑ & ΣΥΝΘΕΤΑ ΞΥΛΟΥ', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 300', NULL, true, NULL, 11, 80),
  ('building', 'BLD-2026-081', 'Κυβόλιθος σκυροδέματος πλακόστρωσης, πάχους 6 cm', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'm²', '44113130-5', 'ΕΛΟΤ ΕΝ 1338', NULL, true, NULL, 12, 81),
  ('building', 'BLD-2026-082', 'Πλάκα πεζοδρομίου σκυροδέματος 40×40×5 cm', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'τεμ', '44113120-2', 'ΕΛΟΤ ΕΝ 1339', NULL, true, NULL, 1.8, 82),
  ('building', 'BLD-2026-083', 'Πλάκα πεζοδρομίου σκυροδέματος 50×50×5 cm', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'τεμ', '44113120-2', 'ΕΛΟΤ ΕΝ 1339', NULL, true, NULL, 2.5, 83),
  ('building', 'BLD-2026-084', 'Πρόχυτο κράσπεδο σκυροδέματος 15×30 cm', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'm', '44114200-4', 'ΕΛΟΤ ΕΝ 1340', NULL, true, NULL, 4.5, 84),
  ('building', 'BLD-2026-085', 'Πρόχυτο ρείθρο (υδρορροή) σκυροδέματος', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'm', '44114200-4', 'ΕΛΟΤ ΕΝ 1340', NULL, true, NULL, 6, 85),
  ('building', 'BLD-2026-086', 'Κράσπεδο φυσικού λίθου (γρανίτη)', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'm', '44912400-0', 'ΕΛΟΤ ΕΝ 1343', NULL, false, NULL, 28, 86),
  ('building', 'BLD-2026-087', 'Τσιμεντοσωλήνας αποχέτευσης οπλισμένος Φ300 mm', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'm', '44114220-0', 'ΕΛΟΤ ΕΝ 1916', NULL, false, NULL, 18, 87),
  ('building', 'BLD-2026-088', 'Πρόχυτο φρεάτιο επίσκεψης σκυροδέματος 40×40 cm', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'τεμ', '44131000-7', 'ΕΛΟΤ ΕΝ 1917', NULL, false, NULL, 35, 88),
  ('building', 'BLD-2026-089', 'Κάλυμμα φρεατίου χυτοσιδηρό ελατού, κλάσης C250 (πεζοδρόμιο)', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'τεμ', '44423740-0', 'ΕΛΟΤ ΕΝ 124', NULL, true, NULL, 45, 89),
  ('building', 'BLD-2026-090', 'Κάλυμμα φρεατίου χυτοσιδηρό ελατού, κλάσης D400 (οδόστρωμα)', NULL, 'ΟΜΑΔΑ Λ — ΠΡΟΪΟΝΤΑ ΣΚΥΡΟΔΕΜΑΤΟΣ & ΥΛΙΚΑ ΟΔΟΣΤΡΩΣΙΑΣ', 'τεμ', '44423740-0', 'ΕΛΟΤ ΕΝ 124', NULL, true, NULL, 85, 90),
  ('building', 'BLD-2026-091', 'Ασφαλτόμιγμα θερμό κλειστού τύπου (συνεχούς κοκκομέτρωσης), ανά τόνο', NULL, 'ΟΜΑΔΑ Μ — ΑΣΦΑΛΤΙΚΑ ΥΛΙΚΑ', 't', '44113620-7', 'ΕΛΟΤ ΕΝ 13108-1 / ΕΤΕΠ 05-03-11-04', NULL, false, NULL, 85, 91),
  ('building', 'BLD-2026-092', 'Ασφαλτικό γαλάκτωμα συγκολλητικής επάλειψης, ανά kg', NULL, 'ΟΜΑΔΑ Μ — ΑΣΦΑΛΤΙΚΑ ΥΛΙΚΑ', 'kg', '44113610-4', 'ΕΛΟΤ ΕΝ 13808', NULL, false, NULL, 1.2, 92),
  ('building', 'BLD-2026-093', 'Ψυχρό ασφαλτόμιγμα επισκευής (σάκος 25 kg)', NULL, 'ΟΜΑΔΑ Μ — ΑΣΦΑΛΤΙΚΑ ΥΛΙΚΑ', 'τεμ', '44113700-2', 'ΕΛΟΤ ΕΝ 13108-1', NULL, false, NULL, 7.5, 93),
  ('building', 'BLD-2026-094', 'Σωλήνας αποχέτευσης PVC-U Φ100 mm, SN4', NULL, 'ΟΜΑΔΑ Ν — ΣΩΛΗΝΩΣΕΙΣ ΑΠΟΧΕΤΕΥΣΗΣ & ΥΔΡΕΥΣΗΣ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1401-1', NULL, false, NULL, 4.5, 94),
  ('building', 'BLD-2026-095', 'Σωλήνας αποχέτευσης PVC-U Φ125 mm, SN4', NULL, 'ΟΜΑΔΑ Ν — ΣΩΛΗΝΩΣΕΙΣ ΑΠΟΧΕΤΕΥΣΗΣ & ΥΔΡΕΥΣΗΣ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1401-1', NULL, false, NULL, 6, 95),
  ('building', 'BLD-2026-096', 'Σωλήνας αποχέτευσης PVC-U Φ160 mm, SN8', NULL, 'ΟΜΑΔΑ Ν — ΣΩΛΗΝΩΣΕΙΣ ΑΠΟΧΕΤΕΥΣΗΣ & ΥΔΡΕΥΣΗΣ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1401-1', NULL, false, NULL, 9.5, 96),
  ('building', 'BLD-2026-097', 'Σωλήνας ύδρευσης πολυαιθυλενίου PE100 Φ32 mm, 16 atm', NULL, 'ΟΜΑΔΑ Ν — ΣΩΛΗΝΩΣΕΙΣ ΑΠΟΧΕΤΕΥΣΗΣ & ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 12201-2', NULL, false, NULL, 1.4, 97),
  ('building', 'BLD-2026-098', 'Σωλήνας ύδρευσης πολυαιθυλενίου PE100 Φ63 mm, 16 atm', NULL, 'ΟΜΑΔΑ Ν — ΣΩΛΗΝΩΣΕΙΣ ΑΠΟΧΕΤΕΥΣΗΣ & ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 12201-2', NULL, false, NULL, 4.2, 98),
  ('building', 'BLD-2026-099', 'Καρφιά οικοδομικά κοινά (σύρματος), ανά kg', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'kg', '44192200-4', 'ΕΛΟΤ ΕΝ 10230-1', NULL, false, NULL, 2.5, 99),
  ('building', 'BLD-2026-100', 'Ξυλόβιδα γαλβανισμένη', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44531100-2', 'ΕΛΟΤ ΕΝ ISO 1478', NULL, false, NULL, 0.03, 100),
  ('building', 'BLD-2026-101', 'Πλαστικό βύσμα στερέωσης με βίδα, Φ8 mm', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44531300-4', '—', NULL, false, NULL, 0.05, 101),
  ('building', 'BLD-2026-102', 'Μεταλλικό αγκύριο διαστολής M10', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44531400-5', '—', NULL, false, NULL, 0.4, 102),
  ('building', 'BLD-2026-103', 'Χημικό αγκύριο (φύσιγγα ρητίνης + ράβδος)', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44831100-5', 'ETAG 001 / EAD 330499', NULL, true, NULL, 3.5, 103),
  ('building', 'BLD-2026-104', 'Συρματόπλεγμα γαλβανισμένο περίφραξης (πλέξης ρόμβου)', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'm²', '44313100-8', 'ΕΛΟΤ ΕΝ 10223-7', NULL, false, NULL, 3, 104),
  ('building', 'BLD-2026-105', 'Γωνιόκρανο επιχρισμάτων γαλβανισμένο/PVC', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'm', '44334000-0', '—', NULL, false, NULL, 0.6, 105),
  ('building', 'BLD-2026-106', 'Σφραγιστική μαστίχη σιλικόνης (ουδέτερη), φύσιγγα 280 ml', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 4.5, 106),
  ('building', 'BLD-2026-107', 'Διογκούμενος αφρός πολυουρεθάνης, φιάλη 750 ml', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44831100-5', '—', NULL, false, NULL, 5.5, 107),
  ('building', 'BLD-2026-108', 'Αυτοκόλλητη στεγανωτική ταινία αλουμινίου', NULL, 'ΟΜΑΔΑ Ξ — ΣΤΕΡΕΩΤΙΚΑ & ΔΙΑΦΟΡΑ ΜΙΚΡΟΫΛΙΚΑ', 'm', '44424200-0', '—', NULL, false, NULL, 1.2, 108),
  ('aggregates', 'AGG-2026-001', 'Άμμος λατομείου θραυστή, κοκκομετρίας 0/4 mm', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 12620', NULL, true, NULL, 18, 1),
  ('aggregates', 'AGG-2026-002', 'Άμμος ποταμίσια (φυσική) πλυμένη', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14211000-3', 'ΕΛΟΤ ΕΝ 12620', NULL, true, NULL, 20, 2),
  ('aggregates', 'AGG-2026-003', 'Θραυστό αδρανές (γαρμπίλι) 4/8 mm', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 12620', NULL, true, NULL, 19, 3),
  ('aggregates', 'AGG-2026-004', 'Θραυστά αδρανή (σκύρα) 8/16 mm', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 12620', NULL, true, NULL, 18, 4),
  ('aggregates', 'AGG-2026-005', 'Θραυστά αδρανή (σκύρα) 16/31,5 mm', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 12620', NULL, true, NULL, 17, 5),
  ('aggregates', 'AGG-2026-006', 'Θραυστό υλικό βάσης/υπόβασης οδοστρωσίας 0/31,5 (τύπου 3Α)', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 13242', NULL, true, NULL, 16, 6),
  ('aggregates', 'AGG-2026-007', 'Αμμοχάλικο φυσικό (συλλεκτό) εξυγίανσης', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 13242', NULL, true, NULL, 15, 7),
  ('aggregates', 'AGG-2026-008', 'Λιθορριπή (φυσικοί ογκόλιθοι προστασίας)', NULL, 'ΟΜΑΔΑ Α — ΑΔΡΑΝΗ ΥΛΙΚΑ', 'm³', '14210000-6', 'ΕΛΟΤ ΕΝ 13383-1', NULL, false, NULL, 22, 8),
  ('asphalt', 'ASP-2026-001', 'Θερμό ασφαλτόμιγμα αντιολισθηρής στρώσης κυκλοφορίας (ΑΣ 12,5)', NULL, 'ΟΜΑΔΑ Α — ΑΣΦΑΛΤΟΜΙΓΜΑΤΑ', 't', '44113620-7', 'ΕΛΟΤ ΕΝ 13108-1', NULL, true, NULL, 75, 1),
  ('asphalt', 'ASP-2026-002', 'Θερμό ασφαλτόμιγμα συνδετικής στρώσης (binder)', NULL, 'ΟΜΑΔΑ Α — ΑΣΦΑΛΤΟΜΙΓΜΑΤΑ', 't', '44113620-7', 'ΕΛΟΤ ΕΝ 13108-1', NULL, true, NULL, 70, 2),
  ('asphalt', 'ASP-2026-003', 'Θερμό ασφαλτόμιγμα ισοπεδωτικής/βάσης', NULL, 'ΟΜΑΔΑ Α — ΑΣΦΑΛΤΟΜΙΓΜΑΤΑ', 't', '44113620-7', 'ΕΛΟΤ ΕΝ 13108-1', NULL, true, NULL, 68, 3),
  ('asphalt', 'ASP-2026-004', 'Ψυχρό ασφαλτόμιγμα επούλωσης οπών (σάκος 25 kg)', NULL, 'ΟΜΑΔΑ Α — ΑΣΦΑΛΤΟΜΙΓΜΑΤΑ', 'τεμ', '44113620-7', 'ΕΛΟΤ ΕΝ 13108-1', NULL, true, NULL, 8, 4),
  ('asphalt', 'ASP-2026-005', 'Ψυχρό ασφαλτόμιγμα επούλωσης οπών (χύδην)', NULL, 'ΟΜΑΔΑ Α — ΑΣΦΑΛΤΟΜΙΓΜΑΤΑ', 't', '44113620-7', 'ΕΛΟΤ ΕΝ 13108-1', NULL, true, NULL, 220, 5),
  ('asphalt', 'ASP-2026-006', 'Αντιολισθηρά αδρανή ασφαλτικών (ψηφίδα επίπασης)', NULL, 'ΟΜΑΔΑ Α — ΑΣΦΑΛΤΟΜΙΓΜΑΤΑ', 't', '14210000-6', 'ΕΛΟΤ ΕΝ 13043', NULL, true, NULL, 35, 6),
  ('asphalt', 'ASP-2026-007', 'Άσφαλτος οδοστρωσίας τύπου 50/70 (penetration)', NULL, 'ΟΜΑΔΑ Β — ΑΣΦΑΛΤΟΙ & ΓΑΛΑΚΤΩΜΑΤΑ', 't', '44113610-4', 'ΕΛΟΤ ΕΝ 12591', NULL, true, NULL, 700, 7),
  ('asphalt', 'ASP-2026-008', 'Τροποποιημένη άσφαλτος πολυμερούς (PmB)', NULL, 'ΟΜΑΔΑ Β — ΑΣΦΑΛΤΟΙ & ΓΑΛΑΚΤΩΜΑΤΑ', 't', '44113610-4', 'ΕΛΟΤ ΕΝ 14023', NULL, true, NULL, 850, 8),
  ('asphalt', 'ASP-2026-009', 'Κατιοντικό ασφαλτικό γαλάκτωμα συγκολλητικής επάλειψης (C60B), ανά kg', NULL, 'ΟΜΑΔΑ Β — ΑΣΦΑΛΤΟΙ & ΓΑΛΑΚΤΩΜΑΤΑ', 'kg', '44113610-4', 'ΕΛΟΤ ΕΝ 13808', NULL, true, NULL, 0.9, 9),
  ('asphalt', 'ASP-2026-010', 'Ασφαλτικό διάλυμα προεπάλειψης (prime/MC), ανά kg', NULL, 'ΟΜΑΔΑ Β — ΑΣΦΑΛΤΟΙ & ΓΑΛΑΚΤΩΜΑΤΑ', 'kg', '44113610-4', 'ΕΛΟΤ ΕΝ 15322', NULL, true, NULL, 1.1, 10),
  ('asphalt', 'ASP-2026-011', 'Ασφαλτικό γαλάκτωμα ταχείας διάσπασης (επίπασης), ανά kg', NULL, 'ΟΜΑΔΑ Β — ΑΣΦΑΛΤΟΙ & ΓΑΛΑΚΤΩΜΑΤΑ', 'kg', '44113610-4', 'ΕΛΟΤ ΕΝ 13808', NULL, true, NULL, 1, 11),
  ('asphalt', 'ASP-2026-012', 'Θερμή ασφαλτική μαστίχη σφράγισης ρωγμών/αρμών, ανά kg', NULL, 'ΟΜΑΔΑ Γ — ΥΛΙΚΑ ΣΦΡΑΓΙΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ ΟΔΩΝ', 'kg', '44113610-4', 'ΕΛΟΤ ΕΝ 14188-1', NULL, true, NULL, 2.5, 12),
  ('asphalt', 'ASP-2026-013', 'Ψυχρή ασφαλτική μαστίχη σφράγισης (κουβάς), ανά kg', NULL, 'ΟΜΑΔΑ Γ — ΥΛΙΚΑ ΣΦΡΑΓΙΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ ΟΔΩΝ', 'kg', '44831100-5', 'ΕΛΟΤ ΕΝ 14188-2', NULL, true, NULL, 3, 13),
  ('asphalt', 'ASP-2026-014', 'Ασφαλτικό επαλειφόμενο στεγανωτικό (γαλάκτωμα), δοχείο 18 kg', NULL, 'ΟΜΑΔΑ Γ — ΥΛΙΚΑ ΣΦΡΑΓΙΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ ΟΔΩΝ', 'τεμ', '44113610-4', 'ΕΛΟΤ ΕΝ 15814', NULL, true, NULL, 35, 14),
  ('asphalt', 'ASP-2026-015', 'Αυτοκόλλητο ασφαλτόπανο επισκευών οδών/πλατειών', NULL, 'ΟΜΑΔΑ Γ — ΥΛΙΚΑ ΣΦΡΑΓΙΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ ΟΔΩΝ', 'm²', '44113610-4', 'ΕΛΟΤ ΕΝ 13707', NULL, true, NULL, 6, 15),
  ('hardware', 'HRD-2026-001', 'Ξυλόβιδα γαλβανισμένη 3,5×30 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531100-2', 'ΕΛΟΤ ΕΝ ISO 1478', NULL, false, NULL, 0.02, 1),
  ('hardware', 'HRD-2026-002', 'Ξυλόβιδα γαλβανισμένη 4×40 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531100-2', 'ΕΛΟΤ ΕΝ ISO 1478', NULL, false, NULL, 0.03, 2),
  ('hardware', 'HRD-2026-003', 'Ξυλόβιδα γαλβανισμένη 4,5×60 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531100-2', 'ΕΛΟΤ ΕΝ ISO 1478', NULL, false, NULL, 0.05, 3),
  ('hardware', 'HRD-2026-004', 'Ξυλόβιδα γαλβανισμένη 5×80 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531100-2', 'ΕΛΟΤ ΕΝ ISO 1478', NULL, false, NULL, 0.08, 4),
  ('hardware', 'HRD-2026-005', 'Ξυλόβιδα κεφαλής Torx (πλακέ) 5×50 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531100-2', 'ΕΛΟΤ ΕΝ ISO 1478', NULL, false, NULL, 0.05, 5),
  ('hardware', 'HRD-2026-006', 'Λαμαρινόβιδα αυτοδιάτρητη (με τρυπάνι) 4,2×19 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531300-4', 'ΕΛΟΤ ΕΝ ISO 15480', NULL, false, NULL, 0.03, 6),
  ('hardware', 'HRD-2026-007', 'Λαμαρινόβιδα 4,8×38 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531300-4', 'ΕΛΟΤ ΕΝ ISO 1479', NULL, false, NULL, 0.05, 7),
  ('hardware', 'HRD-2026-008', 'Βίδα γυψοσανίδας (φωσφατωμένη) 3,5×25 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531300-4', 'ΕΛΟΤ ΕΝ 14566', NULL, true, NULL, 0.01, 8),
  ('hardware', 'HRD-2026-009', 'Βίδα γυψοσανίδας 3,5×35 mm', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531300-4', 'ΕΛΟΤ ΕΝ 14566', NULL, true, NULL, 0.01, 9),
  ('hardware', 'HRD-2026-010', 'Στριφώνι (ξυλόβιδα εξάγωνης κεφαλής) 8×80 mm γαλβ.', NULL, 'ΟΜΑΔΑ Α — ΚΟΧΛΙΕΣ ΞΥΛΟΥ & ΛΑΜΑΡΙΝΑΣ', 'τεμ', '44531100-2', 'DIN 571', NULL, false, NULL, 0.15, 10),
  ('hardware', 'HRD-2026-011', 'Κοχλίας εξάγωνος M8×40, κλάσης 8.8, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531400-5', 'ΕΛΟΤ ΕΝ ISO 4017', NULL, false, NULL, 0.12, 11),
  ('hardware', 'HRD-2026-012', 'Κοχλίας εξάγωνος M10×60, κλάσης 8.8, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531400-5', 'ΕΛΟΤ ΕΝ ISO 4014', NULL, false, NULL, 0.2, 12),
  ('hardware', 'HRD-2026-013', 'Κοχλίας εξάγωνος M12×80, κλάσης 8.8, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531400-5', 'ΕΛΟΤ ΕΝ ISO 4014', NULL, false, NULL, 0.35, 13),
  ('hardware', 'HRD-2026-014', 'Κοχλίας ολόσπειρος (ντίζα) M10×1000 mm, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531510-9', 'ΕΛΟΤ ΕΝ ISO 4014', NULL, false, NULL, 1.2, 14),
  ('hardware', 'HRD-2026-015', 'Παξιμάδι εξάγωνο M8, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531600-7', 'ΕΛΟΤ ΕΝ ISO 4032', NULL, false, NULL, 0.04, 15),
  ('hardware', 'HRD-2026-016', 'Παξιμάδι εξάγωνο M10, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531600-7', 'ΕΛΟΤ ΕΝ ISO 4032', NULL, false, NULL, 0.06, 16),
  ('hardware', 'HRD-2026-017', 'Παξιμάδι αυτασφαλιζόμενο (ασφαλείας) M10', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44531600-7', 'ΕΛΟΤ ΕΝ ISO 7040', NULL, false, NULL, 0.08, 17),
  ('hardware', 'HRD-2026-018', 'Ροδέλα επίπεδη M8, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44532200-0', 'ΕΛΟΤ ΕΝ ISO 7089', NULL, false, NULL, 0.02, 18),
  ('hardware', 'HRD-2026-019', 'Ροδέλα επίπεδη M10, γαλβ.', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44532200-0', 'ΕΛΟΤ ΕΝ ISO 7089', NULL, false, NULL, 0.03, 19),
  ('hardware', 'HRD-2026-020', 'Ροδέλα ασφαλείας (γκρόβερ) M10', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44532200-0', 'DIN 127', NULL, false, NULL, 0.03, 20),
  ('hardware', 'HRD-2026-021', 'Ροδέλα πλατιά (καρότσας) M8', NULL, 'ΟΜΑΔΑ Β — ΚΟΧΛΙΕΣ ΜΕΤΡΙΚΟΙ, ΠΑΞΙΜΑΔΙΑ & ΡΟΔΕΛΕΣ', 'τεμ', '44532200-0', 'ΕΛΟΤ ΕΝ ISO 7093', NULL, false, NULL, 0.04, 21),
  ('hardware', 'HRD-2026-022', 'Πλαστικό βύσμα (ούπα) Φ6 mm', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44530000-4', '—', NULL, false, NULL, 0.02, 22),
  ('hardware', 'HRD-2026-023', 'Πλαστικό βύσμα (ούπα) Φ8 mm', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44530000-4', '—', NULL, false, NULL, 0.03, 23),
  ('hardware', 'HRD-2026-024', 'Πλαστικό βύσμα (ούπα) Φ10 mm', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44530000-4', '—', NULL, false, NULL, 0.04, 24),
  ('hardware', 'HRD-2026-025', 'Βύσμα γυψοσανίδας (μεταλλικό αυτοδιάτρητο)', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44530000-4', '—', NULL, false, NULL, 0.1, 25),
  ('hardware', 'HRD-2026-026', 'Μεταλλικό αγκύριο διαστολής (στρατζαριστό) M8', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44532400-2', 'EAD 330232', NULL, true, NULL, 0.3, 26),
  ('hardware', 'HRD-2026-027', 'Μεταλλικό αγκύριο διαστολής M10', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44532400-2', 'EAD 330232', NULL, true, NULL, 0.45, 27),
  ('hardware', 'HRD-2026-028', 'Αγκύριο μανδύα (sleeve anchor) M12', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44532400-2', 'EAD 330232', NULL, true, NULL, 0.8, 28),
  ('hardware', 'HRD-2026-029', 'Βαρέως τύπου αγκύριο σκυροδέματος (μπετόβιδα) 7,5×100 mm', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44532400-2', 'EAD 330232', NULL, true, NULL, 0.6, 29),
  ('hardware', 'HRD-2026-030', 'Χημικό αγκύριο (φύσιγγα ρητίνης + ράβδος M12)', NULL, 'ΟΜΑΔΑ Γ — ΒΥΣΜΑΤΑ & ΑΓΚΥΡΙΑ', 'τεμ', '44530000-4', 'EAD 330499', NULL, true, NULL, 3.5, 30),
  ('hardware', 'HRD-2026-031', 'Πριτσίνι (ποπ-ρίβετ) αλουμινίου 4×10 mm', NULL, 'ΟΜΑΔΑ Δ — ΛΟΙΠΟΙ ΣΥΝΔΕΣΜΟΙ', 'τεμ', '44532100-9', 'ΕΛΟΤ ΕΝ ISO 15977', NULL, false, NULL, 0.02, 31),
  ('hardware', 'HRD-2026-032', 'Πριτσίνι (ποπ-ρίβετ) αλουμινίου 4,8×16 mm', NULL, 'ΟΜΑΔΑ Δ — ΛΟΙΠΟΙ ΣΥΝΔΕΣΜΟΙ', 'τεμ', '44532100-9', 'ΕΛΟΤ ΕΝ ISO 15977', NULL, false, NULL, 0.03, 32),
  ('hardware', 'HRD-2026-033', 'Σφιγκτήρας σωλήνα (κολιές) ανοξείδωτος Φ16–25 mm', NULL, 'ΟΜΑΔΑ Δ — ΛΟΙΠΟΙ ΣΥΝΔΕΣΜΟΙ', 'τεμ', '44531510-9', 'ΕΛΟΤ ΕΝ ISO 16127', NULL, false, NULL, 0.3, 33),
  ('hardware', 'HRD-2026-034', 'Σφιγκτήρας σωλήνα (κολιές) ανοξείδωτος Φ40–60 mm', NULL, 'ΟΜΑΔΑ Δ — ΛΟΙΠΟΙ ΣΥΝΔΕΣΜΟΙ', 'τεμ', '44531510-9', 'ΕΛΟΤ ΕΝ ISO 16127', NULL, false, NULL, 0.45, 34),
  ('hardware', 'HRD-2026-035', 'Δεματικό πλαστικό (tie-wrap) 4,8×300 mm', NULL, 'ΟΜΑΔΑ Δ — ΛΟΙΠΟΙ ΣΥΝΔΕΣΜΟΙ', 'τεμ', '44322400-7', 'ΕΛΟΤ ΕΝ 62275', NULL, false, NULL, 0.03, 35),
  ('hardware', 'HRD-2026-036', 'Βίδα-γάντζος (κρίκος) γαλβανισμένος', NULL, 'ΟΜΑΔΑ Δ — ΛΟΙΠΟΙ ΣΥΝΔΕΣΜΟΙ', 'τεμ', '44316400-2', '—', NULL, false, NULL, 0.2, 36),
  ('hardware', 'HRD-2026-037', 'Γωνία στήριξης γαλβανισμένη (τζινέτι) 70×70 mm', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'τεμ', '44316400-2', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 0.5, 37),
  ('hardware', 'HRD-2026-038', 'Γωνία στήριξης βαρέως τύπου με νεύρωση 90×90 mm', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'τεμ', '44316400-2', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 0.9, 38),
  ('hardware', 'HRD-2026-039', 'Διάτρητη μεταλλική λάμα (ταινία στήριξης) 2 m', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'τεμ', '44316400-2', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 1.8, 39),
  ('hardware', 'HRD-2026-040', 'Αναρτήρας/στήριγμα δοκού γαλβανισμένος', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'τεμ', '44316400-2', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 1.5, 40),
  ('hardware', 'HRD-2026-041', 'Ναυτικό κλειδί (αγκύλη) γαλβανισμένο 8 mm', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'τεμ', '44316400-2', '—', NULL, false, NULL, 0.6, 41),
  ('hardware', 'HRD-2026-042', 'Εντατήρας συρματόσχοινου (τανκ) M8', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'τεμ', '44316400-2', '—', NULL, false, NULL, 1.8, 42),
  ('hardware', 'HRD-2026-043', 'Αλυσίδα γαλβανισμένη βραχέων κρίκων Φ6 mm', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'm', '44316400-2', 'ΕΛΟΤ ΕΝ 818', NULL, false, NULL, 2.5, 43),
  ('hardware', 'HRD-2026-044', 'Συρματόσχοινο γαλβανισμένο Φ4 mm', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'm', '44316400-2', 'ΕΛΟΤ ΕΝ 12385', NULL, false, NULL, 0.8, 44),
  ('hardware', 'HRD-2026-045', 'Σύρμα γαλβανισμένο Νο 18', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'kg', '44333000-3', 'ΕΛΟΤ ΕΝ 10244-2', NULL, false, NULL, 2.5, 45),
  ('hardware', 'HRD-2026-046', 'Σύρμα μαύρο ανοπτημένο (δεσίματος)', NULL, 'ΟΜΑΔΑ Ε — ΜΕΤΑΛΛΙΚΑ ΣΤΗΡΙΓΜΑΤΑ & ΕΙΔΗ ΚΙΓΚΑΛΕΡΙΑΣ', 'kg', '44333000-3', 'ΕΛΟΤ ΕΝ 10016', NULL, false, NULL, 1.8, 46),
  ('hardware', 'HRD-2026-047', 'Μεντεσές πόρτας/παραθύρου γαλβ. 100 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΜΕΝΤΕΣΕΔΕΣ, ΣΥΡΤΕΣ & ΜΗΧΑΝΙΣΜΟΙ', 'τεμ', '44523100-3', 'ΕΛΟΤ ΕΝ 1935', NULL, true, NULL, 1.2, 47),
  ('hardware', 'HRD-2026-048', 'Μεντεσές βαρέως τύπου (στροφέας) με ρουλεμάν', NULL, 'ΟΜΑΔΑ ΣΤ — ΜΕΝΤΕΣΕΔΕΣ, ΣΥΡΤΕΣ & ΜΗΧΑΝΙΣΜΟΙ', 'τεμ', '44523100-3', 'ΕΛΟΤ ΕΝ 1935', NULL, true, NULL, 3.5, 48),
  ('hardware', 'HRD-2026-049', 'Σύρτης (μάνταλο) ασφαλείας γαλβ. 150 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΜΕΝΤΕΣΕΔΕΣ, ΣΥΡΤΕΣ & ΜΗΧΑΝΙΣΜΟΙ', 'τεμ', '44523200-4', 'ΕΛΟΤ ΕΝ 12051', NULL, true, NULL, 3, 49),
  ('hardware', 'HRD-2026-050', 'Σύρτης λυκάκι πόρτας', NULL, 'ΟΜΑΔΑ ΣΤ — ΜΕΝΤΕΣΕΔΕΣ, ΣΥΡΤΕΣ & ΜΗΧΑΝΙΣΜΟΙ', 'τεμ', '44523200-4', 'ΕΛΟΤ ΕΝ 12051', NULL, true, NULL, 1.5, 50),
  ('hardware', 'HRD-2026-051', 'Μηχανισμός επαναφοράς πόρτας (σούστα/κλείστρο)', NULL, 'ΟΜΑΔΑ ΣΤ — ΜΕΝΤΕΣΕΔΕΣ, ΣΥΡΤΕΣ & ΜΗΧΑΝΙΣΜΟΙ', 'τεμ', '44523200-4', 'ΕΛΟΤ ΕΝ 1154', NULL, true, NULL, 22, 51),
  ('hardware', 'HRD-2026-052', 'Ράουλο/οδηγός συρόμενης πόρτας', NULL, 'ΟΜΑΔΑ ΣΤ — ΜΕΝΤΕΣΕΔΕΣ, ΣΥΡΤΕΣ & ΜΗΧΑΝΙΣΜΟΙ', 'τεμ', '44523200-4', '—', NULL, false, NULL, 4.5, 52),
  ('hardware', 'HRD-2026-053', 'Κλειδαριά χωνευτή πόρτας (μεσόπορτας)', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44521110-2', 'ΕΛΟΤ ΕΝ 12209', NULL, true, NULL, 9, 53),
  ('hardware', 'HRD-2026-054', 'Κλειδαριά ασφαλείας κεντρικής πόρτας με κύλινδρο', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44521110-2', 'ΕΛΟΤ ΕΝ 12209', NULL, true, NULL, 28, 54),
  ('hardware', 'HRD-2026-055', 'Κύλινδρος κλειδαριάς (αφαλός) ασφαλείας 30/30', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44521110-2', 'ΕΛΟΤ ΕΝ 1303', NULL, true, NULL, 7, 55),
  ('hardware', 'HRD-2026-056', 'Κύλινδρος αφαλός με κουμπί (πόμολο) 30/30', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44521110-2', 'ΕΛΟΤ ΕΝ 1303', NULL, true, NULL, 9, 56),
  ('hardware', 'HRD-2026-057', 'Λουκέτο ασφαλείας ατσάλινο 50 mm', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44521210-3', 'ΕΛΟΤ ΕΝ 12320', NULL, false, NULL, 6, 57),
  ('hardware', 'HRD-2026-058', 'Πόμολο πόρτας (χειρολαβή) inox με ροζέτα', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44523200-4', 'ΕΛΟΤ ΕΝ 1906', NULL, false, NULL, 12, 58),
  ('hardware', 'HRD-2026-059', 'Χειρολαβή παραθύρου (μηχανισμός espagnolette)', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44523200-4', 'ΕΛΟΤ ΕΝ 13126-3', NULL, false, NULL, 6, 59),
  ('hardware', 'HRD-2026-060', 'Κλειδαριά επίπλου/συρταριού', NULL, 'ΟΜΑΔΑ Ζ — ΚΛΕΙΔΑΡΙΕΣ, ΚΥΛΙΝΔΡΟΙ & ΧΕΙΡΟΛΑΒΕΣ', 'τεμ', '44521110-2', '—', NULL, false, NULL, 3.5, 60),
  ('air_conditioning', 'HVA-2026-001', 'Κλιματιστικό διαιρούμενο τοίχου inverter 9.000 BTU/h (2,6 kW), R32', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512200-0', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 350, 1),
  ('air_conditioning', 'HVA-2026-002', 'Κλιματιστικό διαιρούμενο τοίχου inverter 12.000 BTU/h (3,5 kW), R32', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512200-0', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 400, 2),
  ('air_conditioning', 'HVA-2026-003', 'Κλιματιστικό διαιρούμενο τοίχου inverter 18.000 BTU/h (5,3 kW), R32', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512200-0', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 550, 3),
  ('air_conditioning', 'HVA-2026-004', 'Κλιματιστικό διαιρούμενο τοίχου inverter 24.000 BTU/h (7,0 kW), R32', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512200-0', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 700, 4),
  ('air_conditioning', 'HVA-2026-005', 'Κλιματιστικό τοίχου inverter 12.000 BTU/h με Wi-Fi & αντλία θερμότητας', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512200-0', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 450, 5),
  ('air_conditioning', 'HVA-2026-006', 'Κλιματιστικό δαπέδου-οροφής (console) 24.000 BTU/h', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 850, 6),
  ('air_conditioning', 'HVA-2026-007', 'Κλιματιστικό τύπου ντουλάπα (floor standing) 36.000 BTU/h', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 1400, 7),
  ('air_conditioning', 'HVA-2026-008', 'Φορητό κλιματιστικό δαπέδου (portable) 12.000 BTU/h', NULL, 'ΟΜΑΔΑ Α — ΔΙΑΙΡΟΥΜΕΝΑ ΚΛΙΜΑΤΙΣΤΙΚΑ (SPLIT)', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 350, 8),
  ('air_conditioning', 'HVA-2026-009', 'Κλιματιστικό τύπου κασέτα οροφής (cassette) 24.000 BTU/h', NULL, 'ΟΜΑΔΑ Β — ΕΠΑΓΓΕΛΜΑΤΙΚΑ & ΚΕΝΤΡΙΚΑ ΣΥΣΤΗΜΑΤΑ', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 1100, 9),
  ('air_conditioning', 'HVA-2026-010', 'Κλιματιστικό καναλάτο (ducted) 36.000 BTU/h', NULL, 'ΟΜΑΔΑ Β — ΕΠΑΓΓΕΛΜΑΤΙΚΑ & ΚΕΝΤΡΙΚΑ ΣΥΣΤΗΜΑΤΑ', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 1500, 10),
  ('air_conditioning', 'HVA-2026-011', 'Πολυδιαιρούμενο σύστημα (multi-split): εξωτ. μονάδα για 2 εσωτερικές', NULL, 'ΟΜΑΔΑ Β — ΕΠΑΓΓΕΛΜΑΤΙΚΑ & ΚΕΝΤΡΙΚΑ ΣΥΣΤΗΜΑΤΑ', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 1200, 11),
  ('air_conditioning', 'HVA-2026-012', 'Σύστημα μεταβλητής παροχής ψυκτικού (VRV/VRF) — εξωτερική μονάδα', NULL, 'ΟΜΑΔΑ Β — ΕΠΑΓΓΕΛΜΑΤΙΚΑ & ΚΕΝΤΡΙΚΑ ΣΥΣΤΗΜΑΤΑ', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 4500, 12),
  ('air_conditioning', 'HVA-2026-013', 'Μονάδα ανεμιστήρα-στοιχείου (fan coil), επιδαπέδια/οροφής', NULL, 'ΟΜΑΔΑ Β — ΕΠΑΓΓΕΛΜΑΤΙΚΑ & ΚΕΝΤΡΙΚΑ ΣΥΣΤΗΜΑΤΑ', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 14511 / ΕΝ 60335-2-40', NULL, true, NULL, 350, 13),
  ('air_conditioning', 'HVA-2026-014', 'Αφυγραντήρας χώρου 20 L/24h', NULL, 'ΟΜΑΔΑ Γ — ΕΞΑΕΡΙΣΜΟΣ & ΑΝΕΜΙΣΤΗΡΕΣ', 'τεμ', '42512000-8', 'ΕΛΟΤ ΕΝ 60335-2-40', NULL, true, NULL, 220, 14),
  ('air_conditioning', 'HVA-2026-015', 'Ανεμιστήρας οροφής', NULL, 'ΟΜΑΔΑ Γ — ΕΞΑΕΡΙΣΜΟΣ & ΑΝΕΜΙΣΤΗΡΕΣ', 'τεμ', '39717100-2', 'ΕΛΟΤ ΕΝ 60335-2-80', NULL, true, NULL, 45, 15),
  ('air_conditioning', 'HVA-2026-016', 'Ανεμιστήρας δαπέδου/κολώνα', NULL, 'ΟΜΑΔΑ Γ — ΕΞΑΕΡΙΣΜΟΣ & ΑΝΕΜΙΣΤΗΡΕΣ', 'τεμ', '39717100-2', 'ΕΛΟΤ ΕΝ 60335-2-80', NULL, true, NULL, 35, 16),
  ('air_conditioning', 'HVA-2026-017', 'Εξαεριστήρας τοίχου/μπάνιου (αξονικός)', NULL, 'ΟΜΑΔΑ Γ — ΕΞΑΕΡΙΣΜΟΣ & ΑΝΕΜΙΣΤΗΡΕΣ', 'τεμ', '39717100-2', 'ΕΛΟΤ ΕΝ 60335-2-80', NULL, true, NULL, 25, 17),
  ('air_conditioning', 'HVA-2026-018', 'Φίλτρο κλιματιστικού (ανταλλακτικό)', NULL, 'ΟΜΑΔΑ Δ — ΑΝΤΑΛΛΑΚΤΙΚΑ & ΑΝΑΛΩΣΙΜΑ', 'τεμ', '42512500-3', '—', NULL, false, NULL, 12, 18),
  ('air_conditioning', 'HVA-2026-019', 'Βάση στήριξης εξωτερικής μονάδας (γαλβανισμένη)', NULL, 'ΟΜΑΔΑ Δ — ΑΝΤΑΛΛΑΚΤΙΚΑ & ΑΝΑΛΩΣΙΜΑ', 'τεμ', '42512500-3', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 18, 19),
  ('air_conditioning', 'HVA-2026-020', 'Ψυκτικό ρευστό R32 (φιάλη), ανά kg', NULL, 'ΟΜΑΔΑ Δ — ΑΝΤΑΛΛΑΚΤΙΚΑ & ΑΝΑΛΩΣΙΜΑ', 'kg', '24110000-8', '—', NULL, false, NULL, 25, 20),
  ('plumbing', 'PLB-2026-001', 'Σωλήνας πολυπροπυλενίου PP-R Φ20×2,8 mm (PN20)', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.9, 1),
  ('plumbing', 'PLB-2026-002', 'Σωλήνας PP-R Φ25×3,5 mm (PN20)', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 1.3, 2),
  ('plumbing', 'PLB-2026-003', 'Σωλήνας PP-R Φ32×4,4 mm (PN20)', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 2, 3),
  ('plumbing', 'PLB-2026-004', 'Σωλήνας PP-R Φ40×5,5 mm (PN20)', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 3.1, 4),
  ('plumbing', 'PLB-2026-005', 'Σωλήνας PP-R Φ50×6,9 mm (PN20)', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 4.8, 5),
  ('plumbing', 'PLB-2026-006', 'Σωλήνας PP-R Φ63×8,6 mm (PN20)', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 7.5, 6),
  ('plumbing', 'PLB-2026-007', 'Σωλήνας δικτυωμένου πολυαιθυλενίου PE-X Φ16×2,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15875', NULL, false, NULL, 1.1, 7),
  ('plumbing', 'PLB-2026-008', 'Σωλήνας δικτυωμένου πολυαιθυλενίου PE-X Φ20×2,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 15875', NULL, false, NULL, 1.6, 8),
  ('plumbing', 'PLB-2026-009', 'Σωλήνας πολυστρωματικός (PE-X/AL/PE-X) Φ16×2,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 21003', NULL, false, NULL, 1.4, 9),
  ('plumbing', 'PLB-2026-010', 'Σωλήνας πολυστρωματικός (PE-X/AL/PE-X) Φ20×2,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 21003', NULL, false, NULL, 2.1, 10),
  ('plumbing', 'PLB-2026-011', 'Σωλήνας πολυστρωματικός (PE-X/AL/PE-X) Φ26×3,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ ISO 21003', NULL, false, NULL, 3.4, 11),
  ('plumbing', 'PLB-2026-012', 'Χαλκοσωλήνας Φ15×1,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 1057', NULL, false, NULL, 4.5, 12),
  ('plumbing', 'PLB-2026-013', 'Χαλκοσωλήνας Φ18×1,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 1057', NULL, false, NULL, 5.4, 13),
  ('plumbing', 'PLB-2026-014', 'Χαλκοσωλήνας Φ22×1,0 mm', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 1057', NULL, false, NULL, 6.8, 14),
  ('plumbing', 'PLB-2026-015', 'Σιδηροσωλήνας γαλβανισμένος με σπείρωμα 1/2"', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 10255', NULL, false, NULL, 3.5, 15),
  ('plumbing', 'PLB-2026-016', 'Σιδηροσωλήνας γαλβανισμένος με σπείρωμα 3/4"', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 10255', NULL, false, NULL, 4.5, 16),
  ('plumbing', 'PLB-2026-017', 'Σιδηροσωλήνας γαλβανισμένος με σπείρωμα 1"', NULL, 'ΟΜΑΔΑ Α — ΣΩΛΗΝΕΣ ΥΔΡΕΥΣΗΣ', 'm', '44162500-8', 'ΕΛΟΤ ΕΝ 10255', NULL, false, NULL, 6, 17),
  ('plumbing', 'PLB-2026-018', 'Γωνία 90° PP-R Φ20 (συγκόλλησης)', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167400-2', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.3, 18),
  ('plumbing', 'PLB-2026-019', 'Ταυ PP-R Φ20', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.4, 19),
  ('plumbing', 'PLB-2026-020', 'Σύνδεσμος (μούφα) PP-R Φ25', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167100-9', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.35, 20),
  ('plumbing', 'PLB-2026-021', 'Ημιμαστός PP-R με αρσενικό σπείρωμα Φ20×1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.8, 21),
  ('plumbing', 'PLB-2026-022', 'Ρακόρ PP-R με θηλυκό σπείρωμα Φ20×1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.85, 22),
  ('plumbing', 'PLB-2026-023', 'Συστολή PP-R Φ32/25', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ ISO 15874', NULL, false, NULL, 0.45, 23),
  ('plumbing', 'PLB-2026-024', 'Ρακόρ πρεσαριστό πολυστρωματικού σωλήνα Φ16×1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ ISO 21003', NULL, false, NULL, 1.6, 24),
  ('plumbing', 'PLB-2026-025', 'Γωνία πρεσαριστή πολυστρωματικού σωλήνα Φ16', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167400-2', 'ΕΛΟΤ ΕΝ ISO 21003', NULL, false, NULL, 1.9, 25),
  ('plumbing', 'PLB-2026-026', 'Ταυ πρεσαριστό πολυστρωματικού σωλήνα Φ16', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ ISO 21003', NULL, false, NULL, 2.4, 26),
  ('plumbing', 'PLB-2026-027', 'Μαστός ορειχάλκινος εξάγωνος 1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 12165', NULL, false, NULL, 0.7, 27),
  ('plumbing', 'PLB-2026-028', 'Γωνία ορειχάλκινη 1/2" (αρσενικό-θηλυκό)', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167400-2', 'ΕΛΟΤ ΕΝ 12165', NULL, false, NULL, 1.1, 28),
  ('plumbing', 'PLB-2026-029', 'Σύνδεσμος (μούφα) ορειχάλκινος 1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167100-9', 'ΕΛΟΤ ΕΝ 12165', NULL, false, NULL, 0.9, 29),
  ('plumbing', 'PLB-2026-030', 'Ταυ ορειχάλκινο 1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 12165', NULL, false, NULL, 1.4, 30),
  ('plumbing', 'PLB-2026-031', 'Συστολικός μαστός ορειχάλκινος 3/4"×1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 12165', NULL, false, NULL, 1, 31),
  ('plumbing', 'PLB-2026-032', 'Ρακόρ θηλυκό (ρακόρ-βίδα) ορειχάλκινο 1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167100-9', 'ΕΛΟΤ ΕΝ 12165', NULL, false, NULL, 1.2, 32),
  ('plumbing', 'PLB-2026-033', 'Γωνία γαλβανισμένη (μαστού) 1/2"', NULL, 'ΟΜΑΔΑ Β — ΕΞΑΡΤΗΜΑΤΑ ΣΩΛΗΝΩΝ ΥΔΡΕΥΣΗΣ', 'τεμ', '44167400-2', 'ΕΛΟΤ ΕΝ 10242', NULL, false, NULL, 0.8, 33),
  ('plumbing', 'PLB-2026-034', 'Σωλήνας αποχέτευσης PVC-U Φ32 mm (εντός κτηρίου)', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.2, 34),
  ('plumbing', 'PLB-2026-035', 'Σωλήνας αποχέτευσης PVC-U Φ40 mm', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.5, 35),
  ('plumbing', 'PLB-2026-036', 'Σωλήνας αποχέτευσης PVC-U Φ50 mm', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.9, 36),
  ('plumbing', 'PLB-2026-037', 'Σωλήνας αποχέτευσης PVC-U Φ75 mm', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 3, 37),
  ('plumbing', 'PLB-2026-038', 'Σωλήνας αποχέτευσης PVC-U Φ110 mm', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 4.2, 38),
  ('plumbing', 'PLB-2026-039', 'Σωλήνας αποχέτευσης PVC-U Φ125 mm', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 5.5, 39),
  ('plumbing', 'PLB-2026-040', 'Σωλήνας αποχέτευσης πολυπροπυλενίου (PP) ηχομειωτικός Φ110 mm', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'm', '44163110-4', 'ΕΛΟΤ ΕΝ 1451-1', NULL, false, NULL, 7.5, 40),
  ('plumbing', 'PLB-2026-041', 'Γωνία αποχέτευσης PVC-U 87°30΄ Φ40', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167400-2', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 0.6, 41),
  ('plumbing', 'PLB-2026-042', 'Γωνία αποχέτευσης PVC-U 45° Φ110', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167400-2', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.8, 42),
  ('plumbing', 'PLB-2026-043', 'Ταυ αποχέτευσης PVC-U Φ110/110', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 2.8, 43),
  ('plumbing', 'PLB-2026-044', 'Ημιταυ (Υ) αποχέτευσης PVC-U 45° Φ110/110', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 3, 44),
  ('plumbing', 'PLB-2026-045', 'Συστολή αποχέτευσης PVC-U Φ110/50', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.2, 45),
  ('plumbing', 'PLB-2026-046', 'Σύνδεσμος (μούφα) αποχέτευσης PVC-U Φ110', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167100-9', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 0.9, 46),
  ('plumbing', 'PLB-2026-047', 'Σύνδεσμος επισκευής (διπλός) αποχέτευσης PVC-U Φ110', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167100-9', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.6, 47),
  ('plumbing', 'PLB-2026-048', 'Στόμιο καθαρισμού (πορτάκι) αποχέτευσης PVC-U Φ110', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 1.5, 48),
  ('plumbing', 'PLB-2026-049', 'Πώμα (τάπα) αποχέτευσης PVC-U Φ50', NULL, 'ΟΜΑΔΑ Γ — ΣΩΛΗΝΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΑΠΟΧΕΤΕΥΣΗΣ ΚΤΗΡΙΟΥ', 'τεμ', '44167300-1', 'ΕΛΟΤ ΕΝ 1329-1', NULL, false, NULL, 0.4, 49),
  ('plumbing', 'PLB-2026-050', 'Σιφώνι δαπέδου PVC με ανοξείδωτη εσχάρα 10×10 cm', NULL, 'ΟΜΑΔΑ Δ — ΣΙΦΩΝΙΑ & ΕΙΔΗ ΑΠΟΡΡΟΗΣ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 1253', NULL, true, NULL, 4.5, 50),
  ('plumbing', 'PLB-2026-051', 'Σιφώνι δαπέδου με εσχάρα 15×15 cm & κόφτρα οσμών', NULL, 'ΟΜΑΔΑ Δ — ΣΙΦΩΝΙΑ & ΕΙΔΗ ΑΠΟΡΡΟΗΣ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 1253', NULL, true, NULL, 7, 51),
  ('plumbing', 'PLB-2026-052', 'Σιφώνι νιπτήρα τύπου «μπουκάλας» 1¼" (χρωμέ/πλαστικό)', NULL, 'ΟΜΑΔΑ Δ — ΣΙΦΩΝΙΑ & ΕΙΔΗ ΑΠΟΡΡΟΗΣ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 274-1', NULL, false, NULL, 3.5, 52),
  ('plumbing', 'PLB-2026-053', 'Σιφώνι πλυντηρίου με ρακόρ & βαλβίδα αντεπιστροφής', NULL, 'ΟΜΑΔΑ Δ — ΣΙΦΩΝΙΑ & ΕΙΔΗ ΑΠΟΡΡΟΗΣ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 274-1', NULL, false, NULL, 4, 53),
  ('plumbing', 'PLB-2026-054', 'Γραμμικό στόμιο απορροής ντους (κανάλι) inox 70 cm', NULL, 'ΟΜΑΔΑ Δ — ΣΙΦΩΝΙΑ & ΕΙΔΗ ΑΠΟΡΡΟΗΣ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 1253', NULL, true, NULL, 35, 54),
  ('plumbing', 'PLB-2026-055', 'Στόμιο/υδρορροή δώματος (καμινάδα απορροής) PVC', NULL, 'ΟΜΑΔΑ Δ — ΣΙΦΩΝΙΑ & ΕΙΔΗ ΑΠΟΡΡΟΗΣ', 'τεμ', '44163110-4', 'ΕΛΟΤ ΕΝ 1253', NULL, true, NULL, 6, 55),
  ('plumbing', 'PLB-2026-056', 'Σφαιρικός διακόπτης (βάνα) ορειχάλκινος 1/2"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ 13828', NULL, false, NULL, 3.5, 56),
  ('plumbing', 'PLB-2026-057', 'Σφαιρικός διακόπτης ορειχάλκινος 3/4"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ 13828', NULL, false, NULL, 4.5, 57),
  ('plumbing', 'PLB-2026-058', 'Σφαιρικός διακόπτης ορειχάλκινος 1"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ 13828', NULL, false, NULL, 6.5, 58),
  ('plumbing', 'PLB-2026-059', 'Συρταρωτή δικλείδα (gate valve) ορειχάλκινη 1¼"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ 1074-2', NULL, false, NULL, 12, 59),
  ('plumbing', 'PLB-2026-060', 'Βαλβίδα αντεπιστροφής (κλαπέ) ορειχάλκινη 3/4"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131140-1', 'ΕΛΟΤ ΕΝ 13959', NULL, false, NULL, 5, 60),
  ('plumbing', 'PLB-2026-061', 'Μειωτής πίεσης νερού 1/2"–3/4" με μανόμετρο', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131140-1', 'ΕΛΟΤ ΕΝ 1567', NULL, false, NULL, 28, 61),
  ('plumbing', 'PLB-2026-062', 'Ασφαλιστική βαλβίδα θερμοσίφωνα 8 bar 1/2"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131140-1', 'ΕΛΟΤ ΕΝ 1490', NULL, false, NULL, 6, 62),
  ('plumbing', 'PLB-2026-063', 'Αυτόματο εξαεριστικό δικτύου 1/2"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131140-1', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 4.5, 63),
  ('plumbing', 'PLB-2026-064', 'Γωνιακός διακόπτης παροχής (χρωμέ) 1/2"×1/2"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131400-0', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 2.5, 64),
  ('plumbing', 'PLB-2026-065', 'Εύκαμπτος σύνδεσμος (σπιράλ) inox παροχής 1/2"×40 cm', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '44167100-9', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 2.2, 65),
  ('plumbing', 'PLB-2026-066', 'Φίλτρο νερού (τύπου Υ) ορειχάλκινο 3/4"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 7, 66),
  ('plumbing', 'PLB-2026-067', 'Βαλβίδα πλωτήρα (φλοτέρ) δεξαμενής 1/2"', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 5.5, 67),
  ('plumbing', 'PLB-2026-068', 'Συλλέκτης (κολεκτέρ) ορειχάλκινος 1" με 3 αναχωρήσεις & διακόπτες', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '42131000-6', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 24, 68),
  ('plumbing', 'PLB-2026-069', 'Υδρόμετρο ταχυμετρικό (μετρητής νερού) 1/2", DN15', NULL, 'ΟΜΑΔΑ Ε — ΔΙΑΚΟΠΤΕΣ, ΒΑΛΒΙΔΕΣ & ΟΡΓΑΝΑ ΔΙΚΤΥΟΥ', 'τεμ', '38421100-3', 'ΕΛΟΤ ΕΝ ISO 4064', NULL, false, NULL, 28, 69),
  ('plumbing', 'PLB-2026-070', 'Λεκάνη αποχωρητηρίου πορσελάνης χαμηλής πίεσης (με καζανάκι)', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411740-3', 'ΕΛΟΤ ΕΝ 997', NULL, true, NULL, 55, 70),
  ('plumbing', 'PLB-2026-071', 'Δοχείο πλύσεως (καζανάκι) χαμηλό, διπλής ροής', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411750-6', 'ΕΛΟΤ ΕΝ 14055', NULL, true, NULL, 22, 71),
  ('plumbing', 'PLB-2026-072', 'Καζανάκι εντοιχιζόμενο πλαστικό με μεταλλική βάση στήριξης', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411750-6', 'ΕΛΟΤ ΕΝ 14055', NULL, true, NULL, 65, 72),
  ('plumbing', 'PLB-2026-073', 'Νιπτήρας πορσελάνης (επικαθήμενος/κρεμαστός)', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411300-7', 'ΕΛΟΤ ΕΝ 14688', NULL, true, NULL, 38, 73),
  ('plumbing', 'PLB-2026-074', 'Κολώνα/ημικολώνα νιπτήρα πορσελάνης', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411300-7', 'ΕΛΟΤ ΕΝ 14688', NULL, true, NULL, 18, 74),
  ('plumbing', 'PLB-2026-075', 'Λεκάνη ουρητηρίου πορσελάνης', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411800-2', 'ΕΛΟΤ ΕΝ 13407', NULL, false, NULL, 70, 75),
  ('plumbing', 'PLB-2026-076', 'Μπιντές πορσελάνης', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411600-0', 'ΕΛΟΤ ΕΝ 14528', NULL, false, NULL, 60, 76),
  ('plumbing', 'PLB-2026-077', 'Νεροχύτης κουζίνας ανοξείδωτος (inox) ένθετος, μονός', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411000-4', 'ΕΛΟΤ ΕΝ 13310', NULL, true, NULL, 45, 77),
  ('plumbing', 'PLB-2026-078', 'Βάση ντους (ντουζιέρα) ακρυλική 80×80 cm', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411400-8', 'ΕΛΟΤ ΕΝ 14527', NULL, false, NULL, 55, 78),
  ('plumbing', 'PLB-2026-079', 'Μπανιέρα ακρυλική 1,70 m', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411200-6', 'ΕΛΟΤ ΕΝ 198', NULL, true, NULL, 120, 79),
  ('plumbing', 'PLB-2026-080', 'Κάλυμμα λεκάνης (καπάκι) θερμοσκληρυνόμενο', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΙΔΗ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411700-1', 'ΕΛΟΤ ΕΝ', NULL, false, NULL, 12, 80),
  ('plumbing', 'PLB-2026-081', 'Αναμικτική μπαταρία νιπτήρα ορειχάλκινη επιχρωμιωμένη', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '42131400-0', 'ΕΛΟΤ ΕΝ 817', NULL, false, NULL, 35, 81),
  ('plumbing', 'PLB-2026-082', 'Αναμικτική μπαταρία νεροχύτη με κινητό ρύγχος', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '42131400-0', 'ΕΛΟΤ ΕΝ 817', NULL, false, NULL, 42, 82),
  ('plumbing', 'PLB-2026-083', 'Αναμικτική μπαταρία λουτρού εξωτερική (μπάνιου-ντους)', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '42131400-0', 'ΕΛΟΤ ΕΝ 817', NULL, false, NULL, 45, 83),
  ('plumbing', 'PLB-2026-084', 'Στήλη ντους με αναμικτική μπαταρία & κεφαλή', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '42131400-0', 'ΕΛΟΤ ΕΝ 817', NULL, false, NULL, 95, 84),
  ('plumbing', 'PLB-2026-085', 'Θερμοστατική μπαταρία ντους', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '42131400-0', 'ΕΛΟΤ ΕΝ 1111', NULL, false, NULL, 110, 85),
  ('plumbing', 'PLB-2026-086', 'Τηλέφωνο ντους με εύκαμπτο σπιράλ & βάση', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411100-5', 'ΕΛΟΤ ΕΝ 1112', NULL, false, NULL, 12, 86),
  ('plumbing', 'PLB-2026-087', 'Βαλβίδα νιπτήρα με υπερχείλιση, χρωμέ 1¼"', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411100-5', 'ΕΛΟΤ ΕΝ 274-1', NULL, false, NULL, 4.5, 87),
  ('plumbing', 'PLB-2026-088', 'Μηχανισμός καζανακιού (βαλβίδα πλήρωσης & εκκένωσης διπλής ροής)', NULL, 'ΟΜΑΔΑ Ζ — ΜΠΑΤΑΡΙΕΣ & ΕΞΑΡΤΗΜΑΤΑ ΕΙΔΩΝ ΥΓΙΕΙΝΗΣ', 'τεμ', '44411750-6', 'ΕΛΟΤ ΕΝ 14055', NULL, true, NULL, 9, 88),
  ('plumbing', 'PLB-2026-089', 'Θερμαντικό σώμα (καλοριφέρ) χαλύβδινο πάνελ τύπου 22, 600×1000 mm', NULL, 'ΟΜΑΔΑ Η — ΘΕΡΜΑΝΣΗ / ΖΕΣΤΟ ΝΕΡΟ ΧΡΗΣΗΣ', 'τεμ', '44621110-3', 'ΕΛΟΤ ΕΝ 442', NULL, false, NULL, 75, 89),
  ('plumbing', 'PLB-2026-090', 'Γωνιακός διακόπτης θερμαντικού σώματος με θερμοστατική κεφαλή', NULL, 'ΟΜΑΔΑ Η — ΘΕΡΜΑΝΣΗ / ΖΕΣΤΟ ΝΕΡΟ ΧΡΗΣΗΣ', 'τεμ', '42131110-0', 'ΕΛΟΤ ΕΝ 215', NULL, false, NULL, 18, 90),
  ('plumbing', 'PLB-2026-091', 'Κυκλοφορητής θέρμανσης ρυθμιζόμενων στροφών (κατά ErP)', NULL, 'ΟΜΑΔΑ Η — ΘΕΡΜΑΝΣΗ / ΖΕΣΤΟ ΝΕΡΟ ΧΡΗΣΗΣ', 'τεμ', '42122130-0', 'ΕΛΟΤ ΕΝ 16297', NULL, false, NULL, 95, 91),
  ('plumbing', 'PLB-2026-092', 'Κλειστό δοχείο διαστολής 8 L', NULL, 'ΟΜΑΔΑ Η — ΘΕΡΜΑΝΣΗ / ΖΕΣΤΟ ΝΕΡΟ ΧΡΗΣΗΣ', 'τεμ', '44611500-1', 'ΕΛΟΤ ΕΝ 13831', NULL, false, NULL, 18, 92),
  ('plumbing', 'PLB-2026-093', 'Θερμομονωτικός μανδύας σωλήνων ελαστομερής Φ22×9 mm', NULL, 'ΟΜΑΔΑ Η — ΘΕΡΜΑΝΣΗ / ΖΕΣΤΟ ΝΕΡΟ ΧΡΗΣΗΣ', 'm', '44115210-4', 'ΕΛΟΤ ΕΝ 14304', NULL, false, NULL, 1.5, 93),
  ('plumbing', 'PLB-2026-094', 'Ηλεκτρικός θερμαντήρας νερού (θερμοσίφωνας) 60 L', NULL, 'ΟΜΑΔΑ Η — ΘΕΡΜΑΝΣΗ / ΖΕΣΤΟ ΝΕΡΟ ΧΡΗΣΗΣ', 'τεμ', '39715100-8', 'ΕΛΟΤ ΕΝ 60335-2-21', NULL, false, NULL, 130, 94),
  ('plumbing', 'PLB-2026-095', 'Ταινία στεγανοποίησης σπειρωμάτων PTFE (τεφλόν) 12 mm×12 m', NULL, 'ΟΜΑΔΑ Θ — ΣΤΕΓΑΝΩΤΙΚΑ, ΣΤΗΡΙΞΕΙΣ & ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 751-3', NULL, false, NULL, 0.8, 95),
  ('plumbing', 'PLB-2026-096', 'Στουπί (λινάρι) στεγανοποίησης με αλοιφή (πάστα) σπειρωμάτων', NULL, 'ΟΜΑΔΑ Θ — ΣΤΕΓΑΝΩΤΙΚΑ, ΣΤΗΡΙΞΕΙΣ & ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44115210-4', 'ΕΛΟΤ ΕΝ 751-2', NULL, false, NULL, 6, 96),
  ('plumbing', 'PLB-2026-097', 'Κόλλα (διαλύτης συγκόλλησης) PVC, δοχείο 250 ml', NULL, 'ΟΜΑΔΑ Θ — ΣΤΕΓΑΝΩΤΙΚΑ, ΣΤΗΡΙΞΕΙΣ & ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 14680', NULL, false, NULL, 6.5, 97),
  ('plumbing', 'PLB-2026-098', 'Λιπαντικό συναρμολόγησης ελαστικών δακτυλίων αποχέτευσης', NULL, 'ΟΜΑΔΑ Θ — ΣΤΕΓΑΝΩΤΙΚΑ, ΣΤΗΡΙΞΕΙΣ & ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44115210-4', '—', NULL, false, NULL, 5, 98),
  ('plumbing', 'PLB-2026-099', 'Στήριγμα (κολάρο) σωλήνα με ήλο, Φ20', NULL, 'ΟΜΑΔΑ Θ — ΣΤΕΓΑΝΩΤΙΚΑ, ΣΤΗΡΙΞΕΙΣ & ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44163210-5', '—', NULL, false, NULL, 0.3, 99),
  ('plumbing', 'PLB-2026-100', 'Ελαστικός δακτύλιος στεγανότητας (λάστιχο) αποχέτευσης Φ110', NULL, 'ΟΜΑΔΑ Θ — ΣΤΕΓΑΝΩΤΙΚΑ, ΣΤΗΡΙΞΕΙΣ & ΜΙΚΡΟΫΛΙΚΑ', 'τεμ', '44425200-7', 'ΕΛΟΤ ΕΝ 681-1', NULL, false, NULL, 0.6, 100),
  ('paint', 'PNT-2026-001', 'Πλαστικό χρώμα εσωτερικών χώρων, λευκό, δοχείο 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 28, 1),
  ('paint', 'PNT-2026-002', 'Πλαστικό χρώμα εσωτερικών χώρων, έγχρωμο (αποχρώσεις), 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 32, 2),
  ('paint', 'PNT-2026-003', 'Οικολογικό πλαστικό χρώμα χαμηλών πτητικών (VOC), 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 38, 3),
  ('paint', 'PNT-2026-004', 'Ακρυλικό χρώμα εξωτερικών χώρων (100% ακρυλικό), 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 45, 4),
  ('paint', 'PNT-2026-005', 'Ελαστομερές στεγανωτικό χρώμα ταρατσών, λευκό, 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 55, 5),
  ('paint', 'PNT-2026-006', 'Σιλοξανικό (σιλικονούχο) χρώμα προσόψεων, 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 50, 6),
  ('paint', 'PNT-2026-007', 'Υδρόχρωμα (κονιάματος) λευκό, δοχείο 10 kg', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 12, 7),
  ('paint', 'PNT-2026-008', 'Τσιμεντόχρωμα ακρυλικό, 9 L', NULL, 'ΟΜΑΔΑ Α — ΧΡΩΜΑΤΑ ΤΟΙΧΟΥ (ΥΔΑΤΙΚΗΣ ΒΑΣΗΣ)', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 40, 8),
  ('paint', 'PNT-2026-009', 'Βερνικόχρωμα (ριπολίνη) διαλύτου, γυαλιστερό, 2,5 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44812210-0', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 22, 9),
  ('paint', 'PNT-2026-010', 'Ντουκόχρωμα (αλκυδικό) ματ, 0,75 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44812210-0', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 9, 10),
  ('paint', 'PNT-2026-011', 'Αντισκωριακό αστάρι μετάλλων (μίνιο), 0,75 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ ISO 12944-5', NULL, false, NULL, 10, 11),
  ('paint', 'PNT-2026-012', 'Αντιδιαβρωτική βαφή μετάλλων απευθείας (direct-to-metal), 2,5 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ ISO 12944', NULL, false, NULL, 28, 12),
  ('paint', 'PNT-2026-013', 'Σφυρήλατο διακοσμητικό χρώμα μετάλλων (hammered), 0,75 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ ISO 12944', NULL, false, NULL, 14, 13),
  ('paint', 'PNT-2026-014', 'Χρώμα διαγράμμισης οδών/δαπέδων (ακρυλικό), δοχείο 4 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44811000-8', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 22, 14),
  ('paint', 'PNT-2026-015', 'Εποξειδικό χρώμα δαπέδου/πισίνας (2 συστατικών), kit', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1504-2', NULL, true, NULL, 60, 15),
  ('paint', 'PNT-2026-016', 'Σπρέι βαφής ακρυλικό, φιάλη 400 ml', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 3.5, 16),
  ('paint', 'PNT-2026-017', 'Αντιμουχλικό/θερμομονωτικό χρώμα εσωτερικών χώρων, 9 L', NULL, 'ΟΜΑΔΑ Β — ΧΡΩΜΑΤΑ ΔΙΑΛΥΤΟΥ, ΜΕΤΑΛΛΟΥ & ΕΙΔΙΚΑ', 'τεμ', '44812220-3', 'ΕΛΟΤ ΕΝ 13300', NULL, false, NULL, 45, 17),
  ('paint', 'PNT-2026-018', 'Ακρυλικό αστάρι νερού γενικής χρήσης, 5 L', NULL, 'ΟΜΑΔΑ Γ — ΑΣΤΑΡΙΑ & ΥΠΟΣΤΡΩΜΑΤΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 18, 18),
  ('paint', 'PNT-2026-019', 'Μικρομοριακό αστάρι διαλύτου (σταθεροποιητικό), 5 L', NULL, 'ΟΜΑΔΑ Γ — ΑΣΤΑΡΙΑ & ΥΠΟΣΤΡΩΜΑΤΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 32, 19),
  ('paint', 'PNT-2026-020', 'Αστάρι πρόσφυσης (γυαλιστερών/πλακιδίων), 1 L', NULL, 'ΟΜΑΔΑ Γ — ΑΣΤΑΡΙΑ & ΥΠΟΣΤΡΩΜΑΤΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 12, 20),
  ('paint', 'PNT-2026-021', 'Μονωτικό αστάρι λεκέδων/καπνιάς, 0,75 L', NULL, 'ΟΜΑΔΑ Γ — ΑΣΤΑΡΙΑ & ΥΠΟΣΤΡΩΜΑΤΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1062-1', NULL, false, NULL, 10, 21),
  ('paint', 'PNT-2026-022', 'Υδαταπωθητικό εμποτισμού (silane/siloxane), 5 L', NULL, 'ΟΜΑΔΑ Γ — ΑΣΤΑΡΙΑ & ΥΠΟΣΤΡΩΜΑΤΑ', 'τεμ', '44810000-1', 'ΕΛΟΤ ΕΝ 1504-2', NULL, true, NULL, 35, 22),
  ('paint', 'PNT-2026-023', 'Βερνίκι ξύλου πολυουρεθανικό διαφανές, 0,75 L', NULL, 'ΟΜΑΔΑ Δ — ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44820000-4', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 12, 23),
  ('paint', 'PNT-2026-024', 'Βελατούρα (αστάρι ξύλου διαλύτου), 0,75 L', NULL, 'ΟΜΑΔΑ Δ — ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44820000-4', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 11, 24),
  ('paint', 'PNT-2026-025', 'Βερνίκι εμποτισμού ξύλου (διακοσμητικό), 0,75 L', NULL, 'ΟΜΑΔΑ Δ — ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44820000-4', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 11, 25),
  ('paint', 'PNT-2026-026', 'Λάδι/κερί προστασίας ξύλου (deck/μασίφ), 1 L', NULL, 'ΟΜΑΔΑ Δ — ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44820000-4', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 14, 26),
  ('paint', 'PNT-2026-027', 'Βερνίκι προστασίας μαρμάρου/πέτρας (ακρυλικό), 1 L', NULL, 'ΟΜΑΔΑ Δ — ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44820000-4', 'ΕΛΟΤ ΕΝ 1504-2', NULL, true, NULL, 16, 27),
  ('paint', 'PNT-2026-028', 'Ασφαλτική μεμβράνη στεγάνωσης οπλισμένη 4 mm (με ψηφίδα)', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'm²', '44112500-3', 'ΕΛΟΤ ΕΝ 13707', NULL, true, NULL, 4.5, 28),
  ('paint', 'PNT-2026-029', 'Ασφαλτικό γαλάκτωμα/βερνίκι προεπάλειψης, δοχείο 18 kg', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'τεμ', '44113610-4', 'ΕΛΟΤ ΕΝ 15814', NULL, false, NULL, 35, 29),
  ('paint', 'PNT-2026-030', 'Επαλειφόμενο στεγανωτικό τσιμεντοειδές 2 συστ. (ταρατσών), 25 kg', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 14891', NULL, true, NULL, 45, 30),
  ('paint', 'PNT-2026-031', 'Ακρυλικό επαλειφόμενο στεγανωτικό ταρατσών, 20 kg', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 1504-2', NULL, true, NULL, 55, 31),
  ('paint', 'PNT-2026-032', 'Πολυουρεθανικό επαλειφόμενο στεγανωτικό, 6 kg', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 1504-2', NULL, true, NULL, 60, 32),
  ('paint', 'PNT-2026-033', 'Στεγανωτικό πρόσμικτο μάζας σκυροδέματος/κονιαμάτων, 5 L', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ 934-2', NULL, true, NULL, 14, 33),
  ('paint', 'PNT-2026-034', 'Ελαστική στεγανωτική ταινία αρμών (για επαλειφόμενα), ανά m', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'm', '44831100-5', 'ΕΛΟΤ ΕΝ 14891', NULL, true, NULL, 3, 34),
  ('paint', 'PNT-2026-035', 'Φράγμα υδρατμών πολυαιθυλενίου 200 μm', NULL, 'ΟΜΑΔΑ Ε — ΣΤΕΓΑΝΩΤΙΚΑ & ΜΟΝΩΣΕΙΣ', 'm²', '44176000-4', 'ΕΛΟΤ ΕΝ 13984', NULL, true, NULL, 0.6, 35),
  ('paint', 'PNT-2026-036', 'Σφραγιστική σιλικόνη ακετική (γυαλιού), φύσιγγα 280 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 3.5, 36),
  ('paint', 'PNT-2026-037', 'Σφραγιστική σιλικόνη ουδέτερη (δομική/προσόψεων), 280 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 5, 37),
  ('paint', 'PNT-2026-038', 'Αντιμουχλική σιλικόνη υγρών χώρων, 280 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-3', NULL, true, NULL, 4, 38),
  ('paint', 'PNT-2026-039', 'Ακρυλική μαστίχη σφράγισης (βαφόμενη), 280 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 2.5, 39),
  ('paint', 'PNT-2026-040', 'Πολυουρεθανική σφραγιστική μαστίχη αρμών δαπέδου, 600 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ ISO 11600', NULL, true, NULL, 8, 40),
  ('paint', 'PNT-2026-041', 'Διογκούμενος αφρός πολυουρεθάνης πιστολιού, 750 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 13165', NULL, true, NULL, 5.5, 41),
  ('paint', 'PNT-2026-042', 'Πυράντοχη σφραγιστική μαστίχη αρμών, 310 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 1366-4', NULL, true, NULL, 9, 42),
  ('paint', 'PNT-2026-043', 'Ασφαλτική μαστίχη σφράγισης αρμών (οδών), 310 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΣΦΡΑΓΙΣΤΙΚΑ & ΑΦΡΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 14188-1', NULL, true, NULL, 5, 43),
  ('paint', 'PNT-2026-044', 'Σπατουλαριστός στόκος ακρυλικός εσωτ., δοχείο 5 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831200-6', 'ΕΛΟΤ ΕΝ 15824', NULL, false, NULL, 14, 44),
  ('paint', 'PNT-2026-045', 'Στόκος σπατουλαρίσματος εξωτ. (τσιμεντοειδής), 20 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831200-6', 'ΕΛΟΤ ΕΝ 998-1', NULL, true, NULL, 16, 45),
  ('paint', 'PNT-2026-046', 'Στόκος ξύλου επισκευαστικός, 250 g', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831200-6', '—', NULL, false, NULL, 4, 46),
  ('paint', 'PNT-2026-047', 'Ακρυλικός στόκος γενικής χρήσης (φύσιγγα), 310 ml', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831200-6', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 2.5, 47),
  ('paint', 'PNT-2026-048', 'Συγκολλητικό κονίαμα πλακιδίων τσιμεντοειδές C2TE, 25 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 12004', NULL, false, NULL, 8, 48),
  ('paint', 'PNT-2026-049', 'Αρμόστοκος πλακιδίων (CG2), 5 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831400-8', 'ΕΛΟΤ ΕΝ 13888', NULL, false, NULL, 6.5, 49),
  ('paint', 'PNT-2026-050', 'Κόλλα μοντάζ πολυμερική (γενικής χρήσης), 290 ml', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '24910000-6', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 5, 50),
  ('paint', 'PNT-2026-051', 'Ξυλόκολλα πολυβινυλική (PVAc) D3, δοχείο 1 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '24910000-6', 'ΕΛΟΤ ΕΝ 204 / ΕΝ 205', NULL, false, NULL, 6.5, 51),
  ('paint', 'PNT-2026-052', 'Εποξειδική κόλλα 2 συστατικών, 24 ml', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '24910000-6', 'ΕΛΟΤ ΕΝ 1504-4', NULL, true, NULL, 6, 52),
  ('paint', 'PNT-2026-053', 'Κόλλα (διαλύτης) συγκόλλησης PVC σωλήνων, 250 ml', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 14680', NULL, false, NULL, 6.5, 53),
  ('paint', 'PNT-2026-054', 'Χημικό αγκύριο (φύσιγγα ρητίνης), 300 ml', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ & ΣΤΟΚΟΙ', 'τεμ', '44831100-5', 'EAD 330499', NULL, true, NULL, 9, 54),
  ('paint', 'PNT-2026-055', 'Εποξειδικό σύστημα βαφής δαπέδου (2 συστ.), 5 kg', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ 1504-2', NULL, true, NULL, 60, 55),
  ('paint', 'PNT-2026-056', 'Ρευστοποιητικό/υπερρευστοποιητικό πρόσμικτο σκυροδέματος, 5 L', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ 934-2', NULL, true, NULL, 14, 56),
  ('paint', 'PNT-2026-057', 'Επιταχυντής/αντιπαγωτικό πρόσμικτο σκυροδέματος, 5 L', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ 934-2', NULL, true, NULL, 12, 57),
  ('paint', 'PNT-2026-058', 'Εποξειδικό υλικό αγκύρωσης/συγκόλλησης (2 συστ.), 1 kg', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ 1504-4', NULL, true, NULL, 18, 58),
  ('paint', 'PNT-2026-059', 'Επισκευαστικό μη συρρικνούμενο κονίαμα (grout), 25 kg', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '44831400-8', 'ΕΛΟΤ ΕΝ 1504-3', NULL, true, NULL, 12, 59),
  ('paint', 'PNT-2026-060', 'Συγκολλητικό γαλάκτωμα παλαιού-νέου σκυροδέματος, 5 L', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ 1504-4', NULL, true, NULL, 16, 60),
  ('paint', 'PNT-2026-061', 'Μετατροπέας σκουριάς (αντισκωριακό), 1 L', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '24957000-7', 'ΕΛΟΤ ΕΝ ISO 12944', NULL, false, NULL, 9, 61),
  ('paint', 'PNT-2026-062', 'Αλγοκτόνο/μυκητοκτόνο καθαρισμού επιφανειών, 1 L', NULL, 'ΟΜΑΔΑ Η — ΧΗΜΙΚΑ ΔΟΜΗΣΗΣ & ΣΥΝΤΗΡΗΣΗΣ', 'τεμ', '44832000-1', '—', NULL, false, NULL, 8, 62),
  ('signage', 'SGN-2026-001', 'Πινακίδα STOP (Ρ-2), οκταγωνική πλευράς 600 mm, αντανακλαστική τύπου ΙΙ', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 38, 1),
  ('signage', 'SGN-2026-002', 'Πινακίδα υποχρεωτικής παραχώρησης προτεραιότητας (Ρ-1), τρίγωνο αντεστραμμένο 600 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 32, 2),
  ('signage', 'SGN-2026-003', 'Πινακίδα απαγόρευσης εισόδου όλων των οχημάτων (Ρ-7), κυκλική Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 3),
  ('signage', 'SGN-2026-004', 'Πινακίδα απαγόρευσης εισόδου φορτηγών (σειρά Ρ), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 4),
  ('signage', 'SGN-2026-005', 'Πινακίδα ορίου ταχύτητας 30 km/h (Ρ-32), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 25, 5),
  ('signage', 'SGN-2026-006', 'Πινακίδα ορίου ταχύτητας 40 km/h (Ρ-32), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 25, 6),
  ('signage', 'SGN-2026-007', 'Πινακίδα ορίου ταχύτητας 50 km/h (Ρ-32), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 25, 7),
  ('signage', 'SGN-2026-008', 'Πινακίδα απαγόρευσης στάθμευσης (Ρ-39), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 25, 8),
  ('signage', 'SGN-2026-009', 'Πινακίδα απαγόρευσης στάσης & στάθμευσης (Ρ-40), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 25, 9),
  ('signage', 'SGN-2026-010', 'Πινακίδα απαγόρευσης προσπεράσματος (σειρά Ρ), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 10),
  ('signage', 'SGN-2026-011', 'Πινακίδα απαγόρευσης αναστροφής (σειρά Ρ), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 11),
  ('signage', 'SGN-2026-012', 'Πινακίδα υποχρεωτικής κατεύθυνσης πορείας (σειρά Ρ), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 12),
  ('signage', 'SGN-2026-013', 'Πινακίδα υποχρεωτικής διέλευσης (σειρά Ρ), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 13),
  ('signage', 'SGN-2026-014', 'Πινακίδα μέγιστου επιτρεπόμενου πλάτους 2,5 m (σειρά Ρ), Φ450 mm', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΡΥΘΜΙΣΤΙΚΕΣ ΠΙΝΑΚΙΔΕΣ (Ρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 28, 14),
  ('signage', 'SGN-2026-015', 'Πινακίδα επικίνδυνης στροφής (σειρά Κ), τρίγωνο πλευράς 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 15),
  ('signage', 'SGN-2026-016', 'Πινακίδα επικίνδυνων διαδοχικών στροφών (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 16),
  ('signage', 'SGN-2026-017', 'Πινακίδα διασταύρωσης (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 17),
  ('signage', 'SGN-2026-018', 'Πινακίδα στένωσης οδοστρώματος (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 18),
  ('signage', 'SGN-2026-019', 'Πινακίδα επικίνδυνης κατωφέρειας (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 19),
  ('signage', 'SGN-2026-020', 'Πινακίδα ολισθηρού οδοστρώματος (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 20),
  ('signage', 'SGN-2026-021', 'Πινακίδα εκτέλεσης εργασιών επί της οδού (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 21),
  ('signage', 'SGN-2026-022', 'Πινακίδα διάβασης πεζών (Κ-15), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 22),
  ('signage', 'SGN-2026-023', 'Πινακίδα κινδύνου λόγω παιδιών (Κ-16), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 23),
  ('signage', 'SGN-2026-024', 'Πινακίδα κινδύνου από διέλευση ζώων (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 24),
  ('signage', 'SGN-2026-025', 'Πινακίδα προαναγγελίας κυκλικού κόμβου (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 25),
  ('signage', 'SGN-2026-026', 'Πινακίδα λοιπών κινδύνων (σειρά Κ), 600 mm', NULL, 'ΟΜΑΔΑ Β — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΑΝΑΓΓΕΛΙΑΣ ΚΙΝΔΥΝΟΥ (Κ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 26),
  ('signage', 'SGN-2026-027', 'Πληροφοριακή πινακίδα διάβασης πεζών (Π-21), τετράγωνη 600×600 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 30, 27),
  ('signage', 'SGN-2026-028', 'Πληροφοριακή κατευθυντήρια πινακίδα αλουμινίου (κατασκευή ανά εμβαδόν)', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'm²', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 60, 28),
  ('signage', 'SGN-2026-029', 'Πινακίδα ονοματοθεσίας οδού (αναγραφή ονόματος)', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992300-0', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 22, 29),
  ('signage', 'SGN-2026-030', 'Πινακίδα αρίθμησης κτιρίου', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992300-0', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 8, 30),
  ('signage', 'SGN-2026-031', 'Πινακίδα στάσης αστικής συγκοινωνίας', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34928440-4', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 35, 31),
  ('signage', 'SGN-2026-032', 'Πληροφοριακή πινακίδα χώρου στάθμευσης (P), 600×600 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 28, 32),
  ('signage', 'SGN-2026-033', 'Πινακίδα θέσης στάθμευσης ΑμεΑ, 400×600 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 26, 33),
  ('signage', 'SGN-2026-034', 'Πρόσθετη πινακίδα (Πρ) απόστασης/ωραρίου ισχύος, 400×250 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 12, 34),
  ('signage', 'SGN-2026-035', 'Πρόσθετη πινακίδα (Πρ) βέλους κατεύθυνσης', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 10, 35),
  ('signage', 'SGN-2026-036', 'Πληροφοριακή πινακίδα τοπωνυμίου/εξόδου αλουμινίου (ανά εμβαδόν)', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'm²', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 60, 36),
  ('signage', 'SGN-2026-037', 'Κυρτός καθρέπτης ελέγχου κυκλοφορίας Φ600 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992000-7', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 45, 37),
  ('signage', 'SGN-2026-038', 'Πληροφοριακή πινακίδα αδιεξόδου, 600×600 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΑΘΕΤΗ ΣΗΜΑΝΣΗ: ΠΛΗΡΟΦΟΡΙΑΚΕΣ (Π) & ΠΡΟΣΘΕΤΕΣ (Πρ)', 'τεμ', '34992200-9', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 28, 38),
  ('signage', 'SGN-2026-039', 'Ιστός στήριξης πινακίδων γαλβανισμένος Φ60 mm, μήκους 3,0 m', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 18, 39),
  ('signage', 'SGN-2026-040', 'Ιστός στήριξης πινακίδων γαλβανισμένος Φ76 mm, μήκους 3,5 m', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 26, 40),
  ('signage', 'SGN-2026-041', 'Ιστός στήριξης πινακίδων γαλβανισμένος Φ89 mm, μήκους 4,0 m', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 34, 41),
  ('signage', 'SGN-2026-042', 'Στύλος ορθογωνικής διατομής γαλβανισμένος 80×40 mm', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'm', '34928472-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 9, 42),
  ('signage', 'SGN-2026-043', 'Μεταλλική βάση έδρασης ιστού με κοχλίες αγκύρωσης', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 24, 43),
  ('signage', 'SGN-2026-044', 'Σύστημα στήριξης πινακίδας σε ιστό (κολάρα/σφιγκτήρες)', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', '—', NULL, false, NULL, 6, 44),
  ('signage', 'SGN-2026-045', 'Αντιπεριστροφικό στήριγμα πινακίδας', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', '—', NULL, false, NULL, 4, 45),
  ('signage', 'SGN-2026-046', 'Τάπα (καπάκι) κορυφής ιστού', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', '—', NULL, false, NULL, 1.5, 46),
  ('signage', 'SGN-2026-047', 'Κλωβός αγκύρωσης ιστού με κοχλίες', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', '—', NULL, false, NULL, 12, 47),
  ('signage', 'SGN-2026-048', 'Πλαίσιο αλουμινίου ενίσχυσης πινακίδας (ανά m)', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'm', '34928471-0', '—', NULL, false, NULL, 6, 48),
  ('signage', 'SGN-2026-049', 'Βραχίονας ανάρτησης πινακίδας υπεράνω οδοστρώματος', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 45, 49),
  ('signage', 'SGN-2026-050', 'Ανοξείδωτη ταινία στερέωσης πινακίδων σε ιστό', NULL, 'ΟΜΑΔΑ Δ — ΣΤΥΛΟΙ, ΒΑΣΕΙΣ & ΕΞΑΡΤΗΜΑΤΑ ΣΤΗΡΙΞΗΣ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928472-7', '—', NULL, false, NULL, 2, 50),
  ('signage', 'SGN-2026-051', 'Αντανακλαστική μεμβράνη τύπου Ι (Engineering Grade)', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 25, 51),
  ('signage', 'SGN-2026-052', 'Αντανακλαστική μεμβράνη τύπου ΙΙ (High Intensity)', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 40, 52),
  ('signage', 'SGN-2026-053', 'Αντανακλαστική μεμβράνη τύπου ΙΙΙ (πρισματική, υψηλής απόδοσης)', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 55, 53),
  ('signage', 'SGN-2026-054', 'Φύλλο αλουμινίου πινακίδας πάχους 2,0 mm', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', 'ΕΛΟΤ ΕΝ 485-2', NULL, false, NULL, 30, 54),
  ('signage', 'SGN-2026-055', 'Φύλλο αλουμινίου πινακίδας πάχους 3,0 mm', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', 'ΕΛΟΤ ΕΝ 485-2', NULL, false, NULL, 42, 55),
  ('signage', 'SGN-2026-056', 'Αυτοκόλλητο μη αντανακλαστικό υλικό (μαύρα σύμβολα)', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', '—', NULL, false, NULL, 18, 56),
  ('signage', 'SGN-2026-057', 'Προστατευτική αντιγκράφιτι μεμβράνη πινακίδων', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'm²', '34928471-0', '—', NULL, false, NULL, 12, 57),
  ('signage', 'SGN-2026-058', 'Υλικό εκτύπωσης/αποτύπωσης συμβόλων πινακίδων', NULL, 'ΟΜΑΔΑ Ε — ΑΝΤΑΝΑΚΛΑΣΤΙΚΕΣ ΜΕΜΒΡΑΝΕΣ & ΥΛΙΚΑ ΠΙΝΑΚΙΔΩΝ', 'τεμ', '34928471-0', '—', NULL, false, NULL, 30, 58),
  ('signage', 'SGN-2026-059', 'Ακρυλικό χρώμα διαγράμμισης λευκό (διαλύτου), δοχείο 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 60, 59),
  ('signage', 'SGN-2026-060', 'Ακρυλικό χρώμα διαγράμμισης κίτρινο (διαλύτου), 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 60, 60),
  ('signage', 'SGN-2026-061', 'Υδατικό χρώμα διαγράμμισης λευκό, 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 55, 61),
  ('signage', 'SGN-2026-062', 'Θερμοπλαστικό υλικό διαγράμμισης λευκό, 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 45, 62),
  ('signage', 'SGN-2026-063', 'Θερμοπλαστικό υλικό διαγράμμισης κίτρινο, 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 45, 63),
  ('signage', 'SGN-2026-064', 'Ψυχροπλαστικό υλικό διαγράμμισης 2 συστατικών (kit)', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1871', NULL, true, NULL, 70, 64),
  ('signage', 'SGN-2026-065', 'Αντανακλαστικά σφαιρίδια ύαλου (drop-on), σάκος 25 kg', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922110-0', 'ΕΛΟΤ ΕΝ 1423/1424', NULL, true, NULL, 20, 65),
  ('signage', 'SGN-2026-066', 'Προκατασκευασμένη θερμοπλαστική σήμανση (σύμβολα/βέλη)', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'm²', '34922100-7', 'ΕΛΟΤ ΕΝ 1790', NULL, true, NULL, 35, 66),
  ('signage', 'SGN-2026-067', 'Αυτοκόλλητη ταινία διαγράμμισης μόνιμη, λευκή (ανά m)', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'm', '34922100-7', 'ΕΛΟΤ ΕΝ 1790', NULL, true, NULL, 6, 67),
  ('signage', 'SGN-2026-068', 'Αραιωτικό/καθαριστικό υλικών διαγράμμισης, δοχείο 5 L', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '44832200-3', '—', NULL, false, NULL, 12, 68),
  ('signage', 'SGN-2026-069', 'Αστάρι πρόσφυσης θερμοπλαστικού, δοχείο 5 L', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', '—', NULL, false, NULL, 22, 69),
  ('signage', 'SGN-2026-070', 'Φόρμες (στένσιλ) διαγράμμισης συμβόλων', NULL, 'ΟΜΑΔΑ ΣΤ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΥΛΙΚΑ ΔΙΑΓΡΑΜΜΙΣΗΣ', 'τεμ', '34922100-7', '—', NULL, false, NULL, 30, 70),
  ('signage', 'SGN-2026-071', 'Διαγράμμιση διαχωριστικής/οριογραμμής (συνεχής ή διακεκομμένη) πλ. 10–12 cm', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'm', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 1.2, 71),
  ('signage', 'SGN-2026-072', 'Διαγράμμιση διάβασης πεζών (τύπου ζέβρα)', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'm²', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 9, 72),
  ('signage', 'SGN-2026-073', 'Διαγράμμιση γραμμής στάσης (STOP)', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'm²', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 9, 73),
  ('signage', 'SGN-2026-074', 'Διαγράμμιση βέλους κατεύθυνσης', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 12, 74),
  ('signage', 'SGN-2026-075', 'Διαγράμμιση οριογραμμής θέσης στάθμευσης', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'm', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 1.5, 75),
  ('signage', 'SGN-2026-076', 'Διαγράμμιση συμβόλου θέσης ΑμεΑ', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 25, 76),
  ('signage', 'SGN-2026-077', 'Διαγράμμιση συμβόλου ποδηλατολωρίδας', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 20, 77),
  ('signage', 'SGN-2026-078', 'Διαγράμμιση γραμμάτων/ενδείξεων επί οδοστρώματος', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'τεμ', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 15, 78),
  ('signage', 'SGN-2026-079', 'Αντιολισθηρή έγχρωμη επίστρωση (ποδηλατόδρομος/λωρίδα)', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'm²', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 18, 79),
  ('signage', 'SGN-2026-080', 'Διαγράμμιση νησίδας/μειωτή ταχύτητας (πληροφοριακή)', NULL, 'ΟΜΑΔΑ Ζ — ΟΡΙΖΟΝΤΙΑ ΣΗΜΑΝΣΗ: ΔΙΑΓΡΑΜΜΙΣΕΙΣ (ΕΙΔΗ ΕΦΑΡΜΟΓΗΣ)', 'm²', '34922100-7', 'ΕΛΟΤ ΕΝ 1436', NULL, false, NULL, 10, 80),
  ('signage', 'SGN-2026-081', 'Κώνος σήμανσης PVC αντανακλαστικός ύψους 50 cm', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928460-0', 'ΕΛΟΤ ΕΝ 13422', NULL, true, NULL, 8, 81),
  ('signage', 'SGN-2026-082', 'Κώνος σήμανσης PVC αντανακλαστικός ύψους 75 cm', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928460-0', 'ΕΛΟΤ ΕΝ 13422', NULL, true, NULL, 14, 82),
  ('signage', 'SGN-2026-083', 'Αναλάμπων φανός εργοταξίου (LED, μπαταρίας)', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928420-8', 'ΕΛΟΤ ΕΝ 12352', NULL, true, NULL, 18, 83),
  ('signage', 'SGN-2026-084', 'Πλαστικό αναδιπλούμενο εμπόδιο εργοταξίου', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928110-2', 'ΕΛΟΤ ΕΝ 13422', NULL, true, NULL, 35, 84),
  ('signage', 'SGN-2026-085', 'Πλαστικό στηθαίο εργοταξίου (πληρούμενο με νερό), ανά τεμ', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928110-2', '—', NULL, false, NULL, 45, 85),
  ('signage', 'SGN-2026-086', 'Αναδιπλούμενη εργοταξιακή πινακίδα αναγγελίας έργων', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928470-3', 'ΕΛΟΤ ΕΝ 12899-1', NULL, true, NULL, 40, 86),
  ('signage', 'SGN-2026-087', 'Αντανακλαστική ταινία οριοθέτησης (ρολό)', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928470-3', '—', NULL, false, NULL, 6, 87),
  ('signage', 'SGN-2026-088', 'Ελαστική βάση (αντίβαρο) κώνου/πινακίδας', NULL, 'ΟΜΑΔΑ Η — ΜΕΣΑ ΕΡΓΟΤΑΞΙΑΚΗΣ ΣΗΜΑΝΣΗΣ & ΑΣΦΑΛΕΙΑΣ', 'τεμ', '34928460-0', '—', NULL, false, NULL, 9, 88),
  ('signage', 'SGN-2026-089', 'Χαλύβδινο στηθαίο ασφαλείας (μονόπλευρο), γαλβανισμένο, ανά m', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'm', '34928320-7', 'ΕΛΟΤ ΕΝ 1317-2', NULL, true, NULL, 28, 89),
  ('signage', 'SGN-2026-090', 'Ορθοστάτης (πάσσαλος) στηθαίου ασφαλείας', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'τεμ', '34928120-5', 'ΕΛΟΤ ΕΝ 1317-2', NULL, true, NULL, 14, 90),
  ('signage', 'SGN-2026-091', 'Απόληξη/αρχή στηθαίου ασφαλείας', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'τεμ', '34928120-5', 'ΕΛΟΤ ΕΝ 1317-4', NULL, true, NULL, 35, 91),
  ('signage', 'SGN-2026-092', 'Στηθαίο σκυροδέματος τύπου New Jersey (προκατασκευασμένο), ανά m', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'm', '34928100-9', 'ΕΛΟΤ ΕΝ 1317-2', NULL, true, NULL, 45, 92),
  ('signage', 'SGN-2026-093', 'Αντανακλαστικός οριοδείκτης οδού (delineator)', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'τεμ', '34928410-5', 'ΕΛΟΤ ΕΝ 12899-3', NULL, true, NULL, 9, 93),
  ('signage', 'SGN-2026-094', 'Ανακλαστικό στοιχείο οδοστρώματος (ήλος/μάτι γάτας)', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'τεμ', '34928410-5', 'ΕΛΟΤ ΕΝ 1463-1', NULL, true, NULL, 1.5, 94),
  ('signage', 'SGN-2026-095', 'Εύκαμπτος επαναφερόμενος πλαστικός οριοδείκτης', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'τεμ', '34928450-7', '—', NULL, false, NULL, 12, 95),
  ('signage', 'SGN-2026-096', 'Προστατευτικό κιγκλίδωμα πεζών γαλβανισμένο, ανά m', NULL, 'ΟΜΑΔΑ Θ — ΣΥΣΤΗΜΑΤΑ ΑΝΑΣΧΕΣΗΣ & ΟΡΙΟΘΕΤΗΣΗΣ', 'm', '34928320-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 35, 96),
  ('signage', 'SGN-2026-097', 'Φωτεινός σηματοδότης οχημάτων 3 πεδίων Φ200 mm (LED)', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΕΙΝΗ ΣΗΜΑΝΣΗ & ΣΗΜΑΤΟΔΟΤΗΣΗ', 'τεμ', '34996100-6', 'ΕΛΟΤ ΕΝ 12368', NULL, true, NULL, 220, 97),
  ('signage', 'SGN-2026-098', 'Φωτεινός σηματοδότης πεζών 2 πεδίων (LED)', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΕΙΝΗ ΣΗΜΑΝΣΗ & ΣΗΜΑΤΟΔΟΤΗΣΗ', 'τεμ', '34996100-6', 'ΕΛΟΤ ΕΝ 12368', NULL, true, NULL, 160, 98),
  ('signage', 'SGN-2026-099', 'Πινακίδα μεταβλητών μηνυμάτων (VMS) τύπου LED', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΕΙΝΗ ΣΗΜΑΝΣΗ & ΣΗΜΑΤΟΔΟΤΗΣΗ', 'τεμ', '34924000-0', 'ΕΛΟΤ ΕΝ 12966', NULL, true, NULL, 1500, 99),
  ('signage', 'SGN-2026-100', 'Παλλόμενος φανός διάβασης (πορτοκαλί, LED)', NULL, 'ΟΜΑΔΑ Ι — ΦΩΤΕΙΝΗ ΣΗΜΑΝΣΗ & ΣΗΜΑΤΟΔΟΤΗΣΗ', 'τεμ', '34928420-8', 'ΕΛΟΤ ΕΝ 12352', NULL, true, NULL, 120, 100),
  ('wood', 'WOD-2026-001', 'Πριστή ξυλεία ερυθρελάτης (λευκή), τάβλες πάχους 2,5 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm³', '03419100-1', 'ΕΛΟΤ ΕΝ 1313 / ΕΝ 14081', NULL, true, NULL, 290, 1),
  ('wood', 'WOD-2026-002', 'Πριστή ξυλεία ερυθρελάτης (λευκή), μαδέρια πάχους 5 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm³', '03419100-1', 'ΕΛΟΤ ΕΝ 1313 / ΕΝ 14081', NULL, true, NULL, 320, 2),
  ('wood', 'WOD-2026-003', 'Πριστή ξυλεία πεύκης, τάβλες', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm³', '03419100-1', 'ΕΛΟΤ ΕΝ 1313', NULL, false, NULL, 300, 3),
  ('wood', 'WOD-2026-004', 'Πριστή ξυλεία ελάτης', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm³', '03419100-1', 'ΕΛΟΤ ΕΝ 1313', NULL, false, NULL, 300, 4),
  ('wood', 'WOD-2026-005', 'Καδρόνι λευκής ξυλείας 5×7,5 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm', '03419100-1', 'ΕΛΟΤ ΕΝ 1313', NULL, false, NULL, 1.2, 5),
  ('wood', 'WOD-2026-006', 'Καδρόνι λευκής ξυλείας 7,5×7,5 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm', '03419100-1', 'ΕΛΟΤ ΕΝ 1313', NULL, false, NULL, 1.7, 6),
  ('wood', 'WOD-2026-007', 'Δοκάρι (μάδερο) λευκής ξυλείας 7,5×15 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm', '03419100-1', 'ΕΛΟΤ ΕΝ 14081', NULL, true, NULL, 3.5, 7),
  ('wood', 'WOD-2026-008', 'Πηχάκι λευκής ξυλείας 2×4 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm', '03419100-1', 'ΕΛΟΤ ΕΝ 1313', NULL, false, NULL, 0.45, 8),
  ('wood', 'WOD-2026-009', 'Τάβλα καλουπώματος (καλουπόξυλο) πεύκης 2,5×20 cm', NULL, 'ΟΜΑΔΑ Α — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΜΑΛΑΚΗ (ΛΕΥΚΗ / ΚΩΝΟΦΟΡΩΝ)', 'm', '03419100-1', 'ΕΛΟΤ ΕΝ 13986', NULL, true, NULL, 1.8, 9),
  ('wood', 'WOD-2026-010', 'Πριστή ξυλεία δρυός (βελανιδιάς)', NULL, 'ΟΜΑΔΑ Β — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΣΚΛΗΡΗ & ΤΡΟΠΙΚΗ', 'm³', '03418100-4', 'ΕΛΟΤ ΕΝ 13556 / ΕΝ 14081', NULL, true, NULL, 850, 10),
  ('wood', 'WOD-2026-011', 'Πριστή ξυλεία οξιάς (φηγού) ατμαρισμένη', NULL, 'ΟΜΑΔΑ Β — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΣΚΛΗΡΗ & ΤΡΟΠΙΚΗ', 'm³', '03418100-4', 'ΕΛΟΤ ΕΝ 13556', NULL, false, NULL, 650, 11),
  ('wood', 'WOD-2026-012', 'Πριστή ξυλεία καστανιάς', NULL, 'ΟΜΑΔΑ Β — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΣΚΛΗΡΗ & ΤΡΟΠΙΚΗ', 'm³', '03418100-4', 'ΕΛΟΤ ΕΝ 13556', NULL, false, NULL, 700, 12),
  ('wood', 'WOD-2026-013', 'Πριστή ξυλεία τροπική Iroko', NULL, 'ΟΜΑΔΑ Β — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΣΚΛΗΡΗ & ΤΡΟΠΙΚΗ', 'm³', '03412000-1', 'ΕΛΟΤ ΕΝ 13556 / ΕΝ 350', NULL, false, NULL, 1400, 13),
  ('wood', 'WOD-2026-014', 'Πριστή ξυλεία τροπική Sapelli', NULL, 'ΟΜΑΔΑ Β — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΣΚΛΗΡΗ & ΤΡΟΠΙΚΗ', 'm³', '03412000-1', 'ΕΛΟΤ ΕΝ 13556 / ΕΝ 350', NULL, false, NULL, 1300, 14),
  ('wood', 'WOD-2026-015', 'Πριστή ξυλεία τροπική Meranti', NULL, 'ΟΜΑΔΑ Β — ΠΡΙΣΤΗ ΞΥΛΕΙΑ ΣΚΛΗΡΗ & ΤΡΟΠΙΚΗ', 'm³', '03412000-1', 'ΕΛΟΤ ΕΝ 13556 / ΕΝ 350', NULL, false, NULL, 1100, 15),
  ('wood', 'WOD-2026-016', 'Κόντρα πλακέ θαλάσσης Okoumé (κόλλα WBP), πάχους 18 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636 / ΕΝ 314-2', NULL, true, NULL, 22, 16),
  ('wood', 'WOD-2026-017', 'Κόντρα πλακέ θαλάσσης Okoumé, πάχους 12 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636 / ΕΝ 314-2', NULL, true, NULL, 16, 17),
  ('wood', 'WOD-2026-018', 'Κόντρα πλακέ θαλάσσης Okoumé, πάχους 9 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636 / ΕΝ 314-2', NULL, true, NULL, 13, 18),
  ('wood', 'WOD-2026-019', 'Κόντρα πλακέ θαλάσσης Okoumé, πάχους 6 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636 / ΕΝ 314-2', NULL, true, NULL, 10, 19),
  ('wood', 'WOD-2026-020', 'Κόντρα πλακέ σημύδας (Betula), πάχους 18 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636', NULL, true, NULL, 28, 20),
  ('wood', 'WOD-2026-021', 'Κόντρα πλακέ σημύδας (Betula), πάχους 12 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636', NULL, true, NULL, 20, 21),
  ('wood', 'WOD-2026-022', 'Κόντρα πλακέ καλουπώματος με φαινολική μεμβράνη (film-faced) 18 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636 / ΕΝ 314-2', NULL, true, NULL, 24, 22),
  ('wood', 'WOD-2026-023', 'Κόντρα πλακέ εσωτερικής χρήσης (κοινό), πάχους 5 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΝΤΡΑ ΠΛΑΚΕ (ΑΝΤΙΚΟΛΛΗΤΑ ΦΥΛΛΑ)', 'm²', '44191100-6', 'ΕΛΟΤ ΕΝ 636', NULL, true, NULL, 7, 23),
  ('wood', 'WOD-2026-024', 'Μοριοσανίδα ακατέργαστη, πάχους 18 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 312', NULL, true, NULL, 9, 24),
  ('wood', 'WOD-2026-025', 'Μοριοσανίδα επικαλυμμένη μελαμίνης, πάχους 18 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 14322', NULL, false, NULL, 14, 25),
  ('wood', 'WOD-2026-026', 'Ινοσανίδα μέσης πυκνότητας (MDF), πάχους 16 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191400-9', 'ΕΛΟΤ ΕΝ 622-5', NULL, true, NULL, 11, 26),
  ('wood', 'WOD-2026-027', 'Ινοσανίδα μέσης πυκνότητας (MDF), πάχους 18 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191400-9', 'ΕΛΟΤ ΕΝ 622-5', NULL, true, NULL, 12, 27),
  ('wood', 'WOD-2026-028', 'Ινοσανίδα MDF λακαρισμένη (βαμμένη), πάχους 18 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191400-9', 'ΕΛΟΤ ΕΝ 622-5', NULL, true, NULL, 22, 28),
  ('wood', 'WOD-2026-029', 'Ινοσανίδα υψηλής πυκνότητας (HDF), πάχους 3 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191400-9', 'ΕΛΟΤ ΕΝ 622-5', NULL, true, NULL, 5, 29),
  ('wood', 'WOD-2026-030', 'Πλάκα προσανατολισμένων ινών (OSB/3), πάχους 15 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 300', NULL, true, NULL, 11, 30),
  ('wood', 'WOD-2026-031', 'Πλάκα προσανατολισμένων ινών (OSB/3), πάχους 18 mm', NULL, 'ΟΜΑΔΑ Δ — ΜΟΡΙΟΣΑΝΙΔΕΣ / MDF / OSB', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 300', NULL, true, NULL, 13, 31),
  ('wood', 'WOD-2026-032', 'Δάπεδο laminate κλάσης χρήσης AC4, πάχους 8 mm', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm²', '44191600-1', 'ΕΛΟΤ ΕΝ 13329', NULL, true, NULL, 12, 32),
  ('wood', 'WOD-2026-033', 'Δάπεδο πολυστρωματικό (engineered) δρυός, πάχους 14 mm', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm²', '44191600-1', 'ΕΛΟΤ ΕΝ 13489', NULL, true, NULL, 35, 33),
  ('wood', 'WOD-2026-034', 'Δάπεδο μασίφ δρυός ραμποτέ, πάχους 22 mm', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm²', '44191600-1', 'ΕΛΟΤ ΕΝ 13226', NULL, true, NULL, 45, 34),
  ('wood', 'WOD-2026-035', 'Επένδυση τοίχου/οροφής ραμποτέ (lambri) πεύκης', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm²', '03419100-1', 'ΕΛΟΤ ΕΝ 14519', NULL, true, NULL, 12, 35),
  ('wood', 'WOD-2026-036', 'Σοβατεπί (περιθώριο δαπέδου) MDF επενδυμένο, ύψους 8 cm', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm', '44191400-9', 'ΕΛΟΤ ΕΝ 622-5', NULL, true, NULL, 1.8, 36),
  ('wood', 'WOD-2026-037', 'Σανίδα εξωτερικού δαπέδου (deck) τροπικού ξύλου', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm²', '03412000-1', 'ΕΛΟΤ ΕΝ 350 / ΕΝ 13556', NULL, false, NULL, 55, 37),
  ('wood', 'WOD-2026-038', 'Φύλλο επένδυσης φυσικού ξύλου (καπλαμάς) δρυός', NULL, 'ΟΜΑΔΑ Ε — ΔΑΠΕΔΑ & ΕΠΕΝΔΥΣΕΙΣ ΞΥΛΟΥ', 'm²', '03419100-1', 'ΕΛΟΤ ΕΝ 13986', NULL, true, NULL, 6, 38),
  ('wood', 'WOD-2026-039', 'Εμποτισμένη ξυλεία (πλανισμένη, εξωτ. χρήσης) καδρόνι 4,5×7 cm', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΜΠΟΤΙΣΜΕΝΗ / ΕΙΔΙΚΗ ΞΥΛΕΙΑ & ΕΞΑΡΤΗΜΑΤΑ', 'm', '03419100-1', 'ΕΛΟΤ ΕΝ 351-1', NULL, false, NULL, 2.2, 39),
  ('wood', 'WOD-2026-040', 'Ξύλινος πάσσαλος εμποτισμένος Φ8 cm × 2,0 m (περίφραξης)', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΜΠΟΤΙΣΜΕΝΗ / ΕΙΔΙΚΗ ΞΥΛΕΙΑ & ΕΞΑΡΤΗΜΑΤΑ', 'τεμ', '44192000-2', 'ΕΛΟΤ ΕΝ 351-1', NULL, false, NULL, 6.5, 40),
  ('wood', 'WOD-2026-041', 'Αντικολλητή δομική ξυλεία (Glulam GL24h)', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΜΠΟΤΙΣΜΕΝΗ / ΕΙΔΙΚΗ ΞΥΛΕΙΑ & ΕΞΑΡΤΗΜΑΤΑ', 'm³', '44191200-7', 'ΕΛΟΤ ΕΝ 14080', NULL, false, NULL, 1200, 41),
  ('wood', 'WOD-2026-042', 'Μάδερο σκαλωσιάς (ικριώματος) λευκής ξυλείας 5×20×400 cm', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΜΠΟΤΙΣΜΕΝΗ / ΕΙΔΙΚΗ ΞΥΛΕΙΑ & ΕΞΑΡΤΗΜΑΤΑ', 'τεμ', '03419100-1', 'ΕΛΟΤ ΕΝ 12811-1', NULL, false, NULL, 22, 42),
  ('wood', 'WOD-2026-043', 'Πλάκα μελαμίνης πάγκου εργασίας (worktop), πάχους 28 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΜΠΟΤΙΣΜΕΝΗ / ΕΙΔΙΚΗ ΞΥΛΕΙΑ & ΕΞΑΡΤΗΜΑΤΑ', 'm²', '44191300-8', 'ΕΛΟΤ ΕΝ 14322', NULL, false, NULL, 28, 43),
  ('wood', 'WOD-2026-044', 'Υπόστρωμα δαπέδου laminate (αφρώδες), πάχους 3 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΕΜΠΟΤΙΣΜΕΝΗ / ΕΙΔΙΚΗ ΞΥΛΕΙΑ & ΕΞΑΡΤΗΜΑΤΑ', 'm²', '44191600-1', '—', NULL, false, NULL, 1.5, 44),
  ('wood', 'WOD-2026-045', 'Ξυλόκολλα πολυβινυλική (PVAc) κατηγορίας D3, δοχείο 1 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ, ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '24910000-6', 'ΕΛΟΤ ΕΝ 204 / ΕΝ 205', NULL, false, NULL, 6.5, 45),
  ('wood', 'WOD-2026-046', 'Πολυουρεθανική κόλλα ξύλου (D4), δοχείο 0,5 kg', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ, ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '24910000-6', 'ΕΛΟΤ ΕΝ 15425', NULL, false, NULL, 9, 46),
  ('wood', 'WOD-2026-047', 'Συντηρητικό-μυκητοκτόνο εμποτισμού ξύλου, δοχείο 1 L', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ, ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44800000-8', 'ΕΛΟΤ ΕΝ 599-1', NULL, false, NULL, 9, 47),
  ('wood', 'WOD-2026-048', 'Βερνίκι ξύλου πολυουρεθανικό διαφανές, δοχείο 750 ml', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ, ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44820000-4', 'ΕΛΟΤ ΕΝ 927-2', NULL, false, NULL, 12, 48),
  ('wood', 'WOD-2026-049', 'Λάδι εμποτισμού/προστασίας ξύλου (deck oil), δοχείο 1 L', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ, ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44800000-8', '—', NULL, false, NULL, 10, 49),
  ('wood', 'WOD-2026-050', 'Στόκος ξύλου επισκευαστικός, δοχείο 250 g', NULL, 'ΟΜΑΔΑ Ζ — ΚΟΛΛΕΣ, ΒΕΡΝΙΚΙΑ & ΣΥΝΤΗΡΗΣΗ ΞΥΛΟΥ', 'τεμ', '44831200-6', '—', NULL, false, NULL, 4, 50),
  ('glass', 'GLS-2026-001', 'Υαλοπίνακας float διαφανής, πάχους 4 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 18, 1),
  ('glass', 'GLS-2026-002', 'Υαλοπίνακας float διαφανής, πάχους 5 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 20, 2),
  ('glass', 'GLS-2026-003', 'Υαλοπίνακας float διαφανής, πάχους 6 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 24, 3),
  ('glass', 'GLS-2026-004', 'Υαλοπίνακας float διαφανής, πάχους 8 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 32, 4),
  ('glass', 'GLS-2026-005', 'Υαλοπίνακας float διαφανής, πάχους 10 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 42, 5),
  ('glass', 'GLS-2026-006', 'Υαλοπίνακας θερμικά ενισχυμένος (heat-strengthened), 6 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1863', NULL, true, NULL, 38, 6),
  ('glass', 'GLS-2026-007', 'Υαλοπίνακας αμμοβολής/όπαλ (εσωτερικός), 5 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 28, 7),
  ('glass', 'GLS-2026-008', 'Υαλοπίνακας οπλισμένος (με συρμάτινο πλέγμα), 6 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-3', NULL, true, NULL, 30, 8),
  ('glass', 'GLS-2026-009', 'Υαλοπίνακας έγχρωμος (φιμέ/bronze), 5 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-2', NULL, true, NULL, 26, 9),
  ('glass', 'GLS-2026-010', 'Υαλοπίνακας ενεργειακός χαμηλής εκπομπής (low-e), 4 mm', NULL, 'ΟΜΑΔΑ Α — ΥΑΛΟΠΙΝΑΚΕΣ ΜΟΝΟΙ (FLOAT & ΕΝΙΣΧΥΜΕΝΟΙ)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1096', NULL, true, NULL, 34, 10),
  ('glass', 'GLS-2026-011', 'Διπλός υαλοπίνακας 4-12-4 mm (διάκενο αέρα)', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 45, 11),
  ('glass', 'GLS-2026-012', 'Διπλός υαλοπίνακας 4-16-4 mm (διάκενο αέρα)', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 48, 12),
  ('glass', 'GLS-2026-013', 'Διπλός υαλοπίνακας 4-16-4 mm low-e με αργό (argon)', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 58, 13),
  ('glass', 'GLS-2026-014', 'Διπλός υαλοπίνακας ενεργειακός 4-15-4 mm low-e/argon', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 60, 14),
  ('glass', 'GLS-2026-015', 'Διπλός υαλοπίνακας με εξωτερικό securit (tempered)', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 70, 15),
  ('glass', 'GLS-2026-016', 'Διπλός υαλοπίνακας με εσωτερικό laminated (τρίπλεξ) ασφαλείας', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 80, 16),
  ('glass', 'GLS-2026-017', 'Διπλός υαλοπίνακας ηχομονωτικός (ασύμμετρος)', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 78, 17),
  ('glass', 'GLS-2026-018', 'Τριπλός υαλοπίνακας (triple glazing) low-e/argon', NULL, 'ΟΜΑΔΑ Β — ΔΙΠΛΟΙ & ΤΡΙΠΛΟΙ ΕΝΕΡΓΕΙΑΚΟΙ ΥΑΛΟΠΙΝΑΚΕΣ (IGU)', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1279', NULL, true, NULL, 95, 18),
  ('glass', 'GLS-2026-019', 'Υαλοπίνακας ασφαλείας securit (tempered), 6 mm', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 12150', NULL, true, NULL, 40, 19),
  ('glass', 'GLS-2026-020', 'Υαλοπίνακας ασφαλείας securit (tempered), 8 mm', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 12150', NULL, true, NULL, 50, 20),
  ('glass', 'GLS-2026-021', 'Υαλοπίνακας ασφαλείας securit (tempered), 10 mm', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 12150', NULL, true, NULL, 62, 21),
  ('glass', 'GLS-2026-022', 'Υαλοπίνακας laminated (τρίπλεξ) 3+3 mm (6,38)', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 14449', NULL, true, NULL, 38, 22),
  ('glass', 'GLS-2026-023', 'Υαλοπίνακας laminated (τρίπλεξ) 4+4 mm (8,38)', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 14449', NULL, true, NULL, 48, 23),
  ('glass', 'GLS-2026-024', 'Υαλοπίνακας laminated ηχομονωτικός 8,8 mm', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 14449', NULL, true, NULL, 60, 24),
  ('glass', 'GLS-2026-025', 'Πυράντοχος υαλοπίνακας κατηγορίας EI30', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 13501-2', NULL, true, NULL, 180, 25),
  ('glass', 'GLS-2026-026', 'Αντιβανδαλιστικός υαλοπίνακας ασφαλείας (κατηγ. P4A)', NULL, 'ΟΜΑΔΑ Γ — ΥΑΛΟΠΙΝΑΚΕΣ ΑΣΦΑΛΕΙΑΣ & ΕΙΔΙΚΟΙ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 356', NULL, true, NULL, 90, 26),
  ('glass', 'GLS-2026-027', 'Φύλλο πλεξιγκλάς (PMMA) διαφανές, πάχους 3 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 7823-1', NULL, false, NULL, 30, 27),
  ('glass', 'GLS-2026-028', 'Φύλλο πλεξιγκλάς (PMMA) διαφανές, πάχους 5 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 7823-1', NULL, false, NULL, 45, 28),
  ('glass', 'GLS-2026-029', 'Φύλλο πλεξιγκλάς (PMMA) διαφανές, πάχους 8 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 7823-1', NULL, false, NULL, 70, 29),
  ('glass', 'GLS-2026-030', 'Φύλλο πλεξιγκλάς (PMMA) έγχρωμο/όπαλ, πάχους 3 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 7823-1', NULL, false, NULL, 36, 30),
  ('glass', 'GLS-2026-031', 'Συμπαγές πολυκαρβονικό φύλλο διαφανές, 4 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 11963', NULL, false, NULL, 55, 31),
  ('glass', 'GLS-2026-032', 'Συμπαγές πολυκαρβονικό φύλλο αντιβανδαλιστικό, 6 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 11963', NULL, false, NULL, 85, 32),
  ('glass', 'GLS-2026-033', 'Κυψελωτό πολυκαρβονικό φύλλο διαφανές, 10 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ 16153', NULL, false, NULL, 18, 33),
  ('glass', 'GLS-2026-034', 'Κυψελωτό πολυκαρβονικό φύλλο, 16 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ 16153', NULL, false, NULL, 26, 34),
  ('glass', 'GLS-2026-035', 'Φύλλο PVC σκληρό (rigid) διαφανές, 2 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', '—', NULL, false, NULL, 22, 35),
  ('glass', 'GLS-2026-036', 'Φύλλο πλεξιγκλάς καθρέπτης (PMMA mirror), 3 mm', NULL, 'ΟΜΑΔΑ Δ — ΠΛΕΞΙΓΚΛΑΣ (PMMA) & ΠΟΛΥΚΑΡΒΟΝΙΚΑ ΦΥΛΛΑ', 'm²', '19520000-7', 'ΕΛΟΤ ΕΝ ISO 7823-1', NULL, false, NULL, 40, 36),
  ('glass', 'GLS-2026-037', 'Καθρέπτης αργύρου (silver), πάχους 4 mm', NULL, 'ΟΜΑΔΑ Ε — ΚΑΘΡΕΠΤΕΣ & ΛΟΙΠΑ ΥΑΛΟΥΡΓΙΚΑ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1036', NULL, true, NULL, 30, 37),
  ('glass', 'GLS-2026-038', 'Καθρέπτης ασφαλείας (με οπίσθια μεμβράνη), 4 mm', NULL, 'ΟΜΑΔΑ Ε — ΚΑΘΡΕΠΤΕΣ & ΛΟΙΠΑ ΥΑΛΟΥΡΓΙΚΑ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 1036', NULL, true, NULL, 40, 38),
  ('glass', 'GLS-2026-039', 'Υαλόπλακα δαπέδου αντιολισθηρή (πατητή)', NULL, 'ΟΜΑΔΑ Ε — ΚΑΘΡΕΠΤΕΣ & ΛΟΙΠΑ ΥΑΛΟΥΡΓΙΚΑ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 14449', NULL, true, NULL, 120, 39),
  ('glass', 'GLS-2026-040', 'Υαλότουβλο (glass block) 19×19×8 cm', NULL, 'ΟΜΑΔΑ Ε — ΚΑΘΡΕΠΤΕΣ & ΛΟΙΠΑ ΥΑΛΟΥΡΓΙΚΑ', 'τεμ', '14820000-5', 'ΕΛΟΤ ΕΝ 1051-1', NULL, true, NULL, 6, 40),
  ('glass', 'GLS-2026-041', 'Διακοσμητικός υαλοπίνακας (χυτός/κατεργασμένος)', NULL, 'ΟΜΑΔΑ Ε — ΚΑΘΡΕΠΤΕΣ & ΛΟΙΠΑ ΥΑΛΟΥΡΓΙΚΑ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 572-5', NULL, true, NULL, 35, 41),
  ('glass', 'GLS-2026-042', 'Κρυστάλλινο ράφι securit 8 mm (κομμένο/λειασμένο)', NULL, 'ΟΜΑΔΑ Ε — ΚΑΘΡΕΠΤΕΣ & ΛΟΙΠΑ ΥΑΛΟΥΡΓΙΚΑ', 'm²', '14820000-5', 'ΕΛΟΤ ΕΝ 12150', NULL, true, NULL, 55, 42),
  ('glass', 'GLS-2026-043', 'Σφραγιστική σιλικόνη υαλοπινάκων ουδέτερη, φύσιγγα 280 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 5, 43),
  ('glass', 'GLS-2026-044', 'Δομική σιλικόνη υαλοπετασμάτων (structural glazing), 600 ml', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'τεμ', '44831100-5', 'ΕΛΟΤ ΕΝ 15651-1', NULL, true, NULL, 12, 44),
  ('glass', 'GLS-2026-045', 'Ταινία στερέωσης υαλοπινάκων διπλής όψης (ανά m)', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'm', '44831100-5', '—', NULL, false, NULL, 3, 45),
  ('glass', 'GLS-2026-046', 'Ελαστικά παρεμβύσματα (τάκοι) έδρασης υαλοπίνακα', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'τεμ', '19520000-7', '—', NULL, false, NULL, 0.3, 46),
  ('glass', 'GLS-2026-047', 'Πηχάκι στερέωσης υαλοπίνακα αλουμινίου (glazing bead), ανά m', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'm', '44316400-2', '—', NULL, false, NULL, 4, 47),
  ('glass', 'GLS-2026-048', 'Αντηλιακή αυτοκόλλητη μεμβράνη υαλοπινάκων', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'm²', '19520000-7', '—', NULL, false, NULL, 18, 48),
  ('glass', 'GLS-2026-049', 'Αδιαφανής/αμμοβολής αυτοκόλλητη μεμβράνη (frosted)', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'm²', '19520000-7', '—', NULL, false, NULL, 16, 49),
  ('glass', 'GLS-2026-050', 'Στιλβωτικό/καθαριστικό υγρό υαλοπινάκων, δοχείο 1 L', NULL, 'ΟΜΑΔΑ ΣΤ — ΥΛΙΚΑ ΤΟΠΟΘΕΤΗΣΗΣ & ΑΡΜΟΛΟΓΗΣΗΣ ΥΑΛΟΠΙΝΑΚΩΝ', 'τεμ', '39830000-9', '—', NULL, false, NULL, 6, 50),
  ('ppe', 'PPE-2026-001', 'Κράνος προστασίας εργοταξίου (βιομηχανικό)', NULL, 'ΟΜΑΔΑ Α — ΠΡΟΣΤΑΣΙΑ ΚΕΦΑΛΗΣ, ΟΦΘΑΛΜΩΝ & ΑΚΟΗΣ', 'τεμ', '18444110-7', 'ΕΛΟΤ ΕΝ 397', NULL, true, NULL, 6, 1),
  ('ppe', 'PPE-2026-002', 'Κράνος προστασίας με ενσωματωμένη προσωπίδα', NULL, 'ΟΜΑΔΑ Α — ΠΡΟΣΤΑΣΙΑ ΚΕΦΑΛΗΣ, ΟΦΘΑΛΜΩΝ & ΑΚΟΗΣ', 'τεμ', '18444110-7', 'ΕΛΟΤ ΕΝ 397', NULL, true, NULL, 14, 2),
  ('ppe', 'PPE-2026-003', 'Γυαλιά προστασίας διαφανή (αντιχαρακτικά/αντιθαμβωτικά)', NULL, 'ΟΜΑΔΑ Α — ΠΡΟΣΤΑΣΙΑ ΚΕΦΑΛΗΣ, ΟΦΘΑΛΜΩΝ & ΑΚΟΗΣ', 'τεμ', '33735100-2', 'ΕΛΟΤ ΕΝ 166', NULL, true, NULL, 4, 3),
  ('ppe', 'PPE-2026-004', 'Προσωπίδα (ασπίδα προστασίας προσώπου)', NULL, 'ΟΜΑΔΑ Α — ΠΡΟΣΤΑΣΙΑ ΚΕΦΑΛΗΣ, ΟΦΘΑΛΜΩΝ & ΑΚΟΗΣ', 'τεμ', '18142000-6', 'ΕΛΟΤ ΕΝ 166', NULL, true, NULL, 9, 4),
  ('ppe', 'PPE-2026-005', 'Ωτοασπίδες με στέκα', NULL, 'ΟΜΑΔΑ Α — ΠΡΟΣΤΑΣΙΑ ΚΕΦΑΛΗΣ, ΟΦΘΑΛΜΩΝ & ΑΚΟΗΣ', 'τεμ', '18143000-3', 'ΕΛΟΤ ΕΝ 352-1', NULL, true, NULL, 6, 5),
  ('ppe', 'PPE-2026-006', 'Ωτοβύσματα μιας χρήσης (συσκευασία)', NULL, 'ΟΜΑΔΑ Α — ΠΡΟΣΤΑΣΙΑ ΚΕΦΑΛΗΣ, ΟΦΘΑΛΜΩΝ & ΑΚΟΗΣ', 'τεμ', '18143000-3', 'ΕΛΟΤ ΕΝ 352-2', NULL, true, NULL, 4, 6),
  ('ppe', 'PPE-2026-007', 'Μάσκα φιλτραρίσματος σωματιδίων FFP2 (μιας χρήσης)', NULL, 'ΟΜΑΔΑ Β — ΠΡΟΣΤΑΣΙΑ ΑΝΑΠΝΟΗΣ', 'τεμ', '18143000-3', 'ΕΛΟΤ ΕΝ 149', NULL, true, NULL, 1.2, 7),
  ('ppe', 'PPE-2026-008', 'Μάσκα φιλτραρίσματος σωματιδίων FFP3 (μιας χρήσης)', NULL, 'ΟΜΑΔΑ Β — ΠΡΟΣΤΑΣΙΑ ΑΝΑΠΝΟΗΣ', 'τεμ', '18143000-3', 'ΕΛΟΤ ΕΝ 149', NULL, true, NULL, 2, 8),
  ('ppe', 'PPE-2026-009', 'Μάσκα ημίσεος προσώπου με φίλτρα (επαναχρησιμοποιούμενη)', NULL, 'ΟΜΑΔΑ Β — ΠΡΟΣΤΑΣΙΑ ΑΝΑΠΝΟΗΣ', 'τεμ', '44611200-8', 'ΕΛΟΤ ΕΝ 140', NULL, true, NULL, 22, 9),
  ('ppe', 'PPE-2026-010', 'Φίλτρα αναπνευστικής μάσκας τύπου A2P3 (ζεύγος)', NULL, 'ΟΜΑΔΑ Β — ΠΡΟΣΤΑΣΙΑ ΑΝΑΠΝΟΗΣ', 'τεμ', '44611200-8', 'ΕΛΟΤ ΕΝ 14387', NULL, true, NULL, 12, 10),
  ('ppe', 'PPE-2026-011', 'Γάντια εργασίας μηχανικών κινδύνων (επικάλυψη νιτριλίου), ζεύγος', NULL, 'ΟΜΑΔΑ Γ — ΠΡΟΣΤΑΣΙΑ ΧΕΡΙΩΝ (ΓΑΝΤΙΑ)', 'ζεύγος', '18141000-9', 'ΕΛΟΤ ΕΝ 388', NULL, true, NULL, 2.5, 11),
  ('ppe', 'PPE-2026-012', 'Γάντια δερμάτινα ενισχυμένα, ζεύγος', NULL, 'ΟΜΑΔΑ Γ — ΠΡΟΣΤΑΣΙΑ ΧΕΡΙΩΝ (ΓΑΝΤΙΑ)', 'ζεύγος', '18141000-9', 'ΕΛΟΤ ΕΝ 388', NULL, true, NULL, 4, 12),
  ('ppe', 'PPE-2026-013', 'Γάντια προστασίας από χημικά (νιτριλίου, μακριά), ζεύγος', NULL, 'ΟΜΑΔΑ Γ — ΠΡΟΣΤΑΣΙΑ ΧΕΡΙΩΝ (ΓΑΝΤΙΑ)', 'ζεύγος', '18424000-7', 'ΕΛΟΤ ΕΝ ISO 374-1', NULL, true, NULL, 5, 13),
  ('ppe', 'PPE-2026-014', 'Γάντια προστασίας από θερμότητα/συγκόλληση, ζεύγος', NULL, 'ΟΜΑΔΑ Γ — ΠΡΟΣΤΑΣΙΑ ΧΕΡΙΩΝ (ΓΑΝΤΙΑ)', 'ζεύγος', '18424500-2', 'ΕΛΟΤ ΕΝ 407', NULL, true, NULL, 9, 14),
  ('ppe', 'PPE-2026-015', 'Γάντια μονωτικά ηλεκτρολόγου (κλάση 0, έως 1000 V), ζεύγος', NULL, 'ΟΜΑΔΑ Γ — ΠΡΟΣΤΑΣΙΑ ΧΕΡΙΩΝ (ΓΑΝΤΙΑ)', 'ζεύγος', '18424000-7', 'ΕΛΟΤ ΕΝ 60903', NULL, true, NULL, 35, 15),
  ('ppe', 'PPE-2026-016', 'Γάντια μιας χρήσης νιτριλίου (κουτί 100 τεμ)', NULL, 'ΟΜΑΔΑ Γ — ΠΡΟΣΤΑΣΙΑ ΧΕΡΙΩΝ (ΓΑΝΤΙΑ)', 'τεμ', '18424300-0', 'ΕΛΟΤ ΕΝ ISO 374-1', NULL, true, NULL, 8, 16),
  ('ppe', 'PPE-2026-017', 'Υποδήματα ασφαλείας S3 (προστασία δακτύλων & αντιδιατρητική σόλα), ζεύγος', NULL, 'ΟΜΑΔΑ Δ — ΠΡΟΣΤΑΣΙΑ ΠΟΔΙΩΝ (ΥΠΟΔΗΜΑΤΑ ΑΣΦΑΛΕΙΑΣ)', 'ζεύγος', '18830000-6', 'ΕΛΟΤ ΕΝ ISO 20345', NULL, true, NULL, 35, 17),
  ('ppe', 'PPE-2026-018', 'Μποτάκια ασφαλείας S3 (ψηλά), ζεύγος', NULL, 'ΟΜΑΔΑ Δ — ΠΡΟΣΤΑΣΙΑ ΠΟΔΙΩΝ (ΥΠΟΔΗΜΑΤΑ ΑΣΦΑΛΕΙΑΣ)', 'ζεύγος', '18830000-6', 'ΕΛΟΤ ΕΝ ISO 20345', NULL, true, NULL, 42, 18),
  ('ppe', 'PPE-2026-019', 'Άρβυλα ασφαλείας S1P (αναπνέοντα), ζεύγος', NULL, 'ΟΜΑΔΑ Δ — ΠΡΟΣΤΑΣΙΑ ΠΟΔΙΩΝ (ΥΠΟΔΗΜΑΤΑ ΑΣΦΑΛΕΙΑΣ)', 'ζεύγος', '18830000-6', 'ΕΛΟΤ ΕΝ ISO 20345', NULL, true, NULL, 30, 19),
  ('ppe', 'PPE-2026-020', 'Γαλότσες ασφαλείας S5 (αδιάβροχες με προστασία), ζεύγος', NULL, 'ΟΜΑΔΑ Δ — ΠΡΟΣΤΑΣΙΑ ΠΟΔΙΩΝ (ΥΠΟΔΗΜΑΤΑ ΑΣΦΑΛΕΙΑΣ)', 'ζεύγος', '18812200-6', 'ΕΛΟΤ ΕΝ ISO 20345', NULL, true, NULL, 22, 20),
  ('ppe', 'PPE-2026-021', 'Αντιδιατρητικά πέλματα (ανταλλακτικά), ζεύγος', NULL, 'ΟΜΑΔΑ Δ — ΠΡΟΣΤΑΣΙΑ ΠΟΔΙΩΝ (ΥΠΟΔΗΜΑΤΑ ΑΣΦΑΛΕΙΑΣ)', 'ζεύγος', '18830000-6', 'ΕΛΟΤ ΕΝ ISO 20345', NULL, true, NULL, 8, 21),
  ('ppe', 'PPE-2026-022', 'Γιλέκο υψηλής ευκρίνειας (αντανακλαστικό)', NULL, 'ΟΜΑΔΑ Ε — ΠΡΟΣΤΑΤΕΥΤΙΚΟΣ ΡΟΥΧΙΣΜΟΣ & ΟΡΑΤΟΤΗΤΑ', 'τεμ', '35113440-7', 'ΕΛΟΤ ΕΝ ISO 20471', NULL, true, NULL, 6, 22),
  ('ppe', 'PPE-2026-023', 'Μπουφάν εργασίας υψηλής ευκρίνειας (αδιάβροχο)', NULL, 'ΟΜΑΔΑ Ε — ΠΡΟΣΤΑΤΕΥΤΙΚΟΣ ΡΟΥΧΙΣΜΟΣ & ΟΡΑΤΟΤΗΤΑ', 'τεμ', '35113440-7', 'ΕΛΟΤ ΕΝ ISO 20471', NULL, true, NULL, 35, 23),
  ('ppe', 'PPE-2026-024', 'Ολόσωμη φόρμα εργασίας (παντελόνι & μπλούζα)', NULL, 'ΟΜΑΔΑ Ε — ΠΡΟΣΤΑΤΕΥΤΙΚΟΣ ΡΟΥΧΙΣΜΟΣ & ΟΡΑΤΟΤΗΤΑ', 'τεμ', '18114000-1', 'ΕΛΟΤ ΕΝ ISO 13688', NULL, true, NULL, 25, 24),
  ('ppe', 'PPE-2026-025', 'Αδιάβροχο κοστούμι εργασίας (νιτσεράδα)', NULL, 'ΟΜΑΔΑ Ε — ΠΡΟΣΤΑΤΕΥΤΙΚΟΣ ΡΟΥΧΙΣΜΟΣ & ΟΡΑΤΟΤΗΤΑ', 'τεμ', '35113400-3', 'ΕΛΟΤ ΕΝ 343', NULL, true, NULL, 18, 25),
  ('ppe', 'PPE-2026-026', 'Ποδιά προστασίας (συγκόλλησης/χημικών)', NULL, 'ΟΜΑΔΑ Ε — ΠΡΟΣΤΑΤΕΥΤΙΚΟΣ ΡΟΥΧΙΣΜΟΣ & ΟΡΑΤΟΤΗΤΑ', 'τεμ', '35113400-3', 'ΕΛΟΤ ΕΝ ISO 13688', NULL, true, NULL, 12, 26),
  ('ppe', 'PPE-2026-027', 'Ολόσωμη εξάρτυση ασφαλείας (ζώνη ανάσχεσης πτώσης)', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΡΟΣΤΑΣΙΑ ΑΠΟ ΠΤΩΣΗ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '18143000-3', 'ΕΛΟΤ ΕΝ 361', NULL, true, NULL, 35, 27),
  ('ppe', 'PPE-2026-028', 'Αναδέτης με αποσβεστήρα ενέργειας', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΡΟΣΤΑΣΙΑ ΑΠΟ ΠΤΩΣΗ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '18143000-3', 'ΕΛΟΤ ΕΝ 354/355', NULL, true, NULL, 25, 28),
  ('ppe', 'PPE-2026-029', 'Επιγονατίδες προστασίας, ζεύγος', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΡΟΣΤΑΣΙΑ ΑΠΟ ΠΤΩΣΗ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'ζεύγος', '18143000-3', 'ΕΛΟΤ ΕΝ 14404', NULL, true, NULL, 8, 29),
  ('ppe', 'PPE-2026-030', 'Φορητό φαρμακείο πρώτων βοηθειών εργοταξίου', NULL, 'ΟΜΑΔΑ ΣΤ — ΠΡΟΣΤΑΣΙΑ ΑΠΟ ΠΤΩΣΗ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '33141623-3', '—', NULL, true, NULL, 25, 30),
  ('tools', 'TLS-2026-001', 'Φτυάρι μυτερό με στειλιάρι', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44511100-6', '—', NULL, false, NULL, 12, 1),
  ('tools', 'TLS-2026-002', 'Φτυάρι τετράγωνο (φαρδύ) με στειλιάρι', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44511100-6', '—', NULL, false, NULL, 12, 2),
  ('tools', 'TLS-2026-003', 'Τσάπα (σκαπτικό) με στειλιάρι', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44511300-8', '—', NULL, false, NULL, 14, 3),
  ('tools', 'TLS-2026-004', 'Κασμάς (αξίνα)', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44511300-8', '—', NULL, false, NULL, 16, 4),
  ('tools', 'TLS-2026-005', 'Τσουγκράνα μεταλλική', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44511300-8', '—', NULL, false, NULL, 10, 5),
  ('tools', 'TLS-2026-006', 'Λοστός (ντεκαπέ) 1,2 m', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44511000-5', '—', NULL, false, NULL, 18, 6),
  ('tools', 'TLS-2026-007', 'Βαριά (ματσόλα) 5 kg με στειλιάρι', NULL, 'ΟΜΑΔΑ Α — ΧΩΜΑΤΟΥΡΓΙΚΑ & ΚΡΟΥΣΤΙΚΑ ΒΑΡΕΑ ΕΡΓΑΛΕΙΑ', 'τεμ', '44512300-5', '—', NULL, false, NULL, 22, 7),
  ('tools', 'TLS-2026-008', 'Σφυρί καρφωτικό 500 g', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512300-5', '—', NULL, false, NULL, 8, 8),
  ('tools', 'TLS-2026-009', 'Σφυρί μηχανικού (πένας) 300 g', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512300-5', '—', NULL, false, NULL, 7, 9),
  ('tools', 'TLS-2026-010', 'Λαστιχόσφυρα (πλαστικό σφυρί)', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512300-5', '—', NULL, false, NULL, 6, 10),
  ('tools', 'TLS-2026-011', 'Πένσα ηλεκτρολόγου μονωμένη 180 mm', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512200-4', 'ΕΛΟΤ ΕΝ IEC 60900', NULL, false, NULL, 9, 11),
  ('tools', 'TLS-2026-012', 'Πλαγιοκόφτης 160 mm', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512200-4', '—', NULL, false, NULL, 8, 12),
  ('tools', 'TLS-2026-013', 'Μυτοτσίμπιδο 160 mm', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512200-4', '—', NULL, false, NULL, 8, 13),
  ('tools', 'TLS-2026-014', 'Γκαζοτανάλια ρυθμιζόμενη 250 mm', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512200-4', '—', NULL, false, NULL, 12, 14),
  ('tools', 'TLS-2026-015', 'Σφιγκτήρας (νταβίδι) τύπου F 300 mm', NULL, 'ΟΜΑΔΑ Β — ΚΡΟΥΣΤΙΚΑ & ΕΡΓΑΛΕΙΑ ΣΥΓΚΡΑΤΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 9, 15),
  ('tools', 'TLS-2026-016', 'Κατσαβίδι ίσιο 6×100 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512800-0', 'ΕΛΟΤ ΕΝ ISO 2380', NULL, false, NULL, 3.5, 16),
  ('tools', 'TLS-2026-017', 'Κατσαβίδι σταυρός PH2×100 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512800-0', 'ΕΛΟΤ ΕΝ ISO 8764', NULL, false, NULL, 3.5, 17),
  ('tools', 'TLS-2026-018', 'Σετ κατσαβίδια (6 τεμ)', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512800-0', '—', NULL, false, NULL, 14, 18),
  ('tools', 'TLS-2026-019', 'Σετ καρυδάκια καστάνιας 1/2" (24 τεμ)', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 35, 19),
  ('tools', 'TLS-2026-020', 'Σετ γερμανοπολύγωνα κλειδιά (8–22 mm)', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', 'ΕΛΟΤ ΕΝ ISO 3318', NULL, false, NULL, 28, 20),
  ('tools', 'TLS-2026-021', 'Ρυθμιζόμενο κλειδί (γαλλικό) 250 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', 'ΕΛΟΤ ΕΝ ISO 6787', NULL, false, NULL, 12, 21),
  ('tools', 'TLS-2026-022', 'Πριόνι χειρός ξυλείας 500 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44511500-0', '—', NULL, false, NULL, 9, 22),
  ('tools', 'TLS-2026-023', 'Σιδεροπρίονο (τόξο) με λάμα', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44511500-0', '—', NULL, false, NULL, 8, 23),
  ('tools', 'TLS-2026-024', 'Κόφτης πλακιδίων χειρός 600 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 35, 24),
  ('tools', 'TLS-2026-025', 'Ψαλίδι λαμαρίνας 250 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 12, 25),
  ('tools', 'TLS-2026-026', 'Σκαρπέλο/καλέμι δομικό 250 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 6, 26),
  ('tools', 'TLS-2026-027', 'Μαχαίρι κοπής (cutter) επαγγελματικό 18 mm', NULL, 'ΟΜΑΔΑ Γ — ΚΟΧΛΙΩΣΗΣ & ΚΟΠΗΣ ΧΕΙΡΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 4, 27),
  ('tools', 'TLS-2026-028', 'Μυστρί χτισίματος inox', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 7, 28),
  ('tools', 'TLS-2026-029', 'Σπάτουλα ανοξείδωτη 10 cm', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 4, 29),
  ('tools', 'TLS-2026-030', 'Φραγκόφτυαρο (μάλα) λείανσης σοβά', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 8, 30),
  ('tools', 'TLS-2026-031', 'Λίμα (πλακέ/στρογγυλή) με λαβή', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512700-9', '—', NULL, false, NULL, 6, 31),
  ('tools', 'TLS-2026-032', 'Μετροταινία 5 m', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 6, 32),
  ('tools', 'TLS-2026-033', 'Αλφάδι (πνευματικό) 60 cm', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 12, 33),
  ('tools', 'TLS-2026-034', 'Νήμα στάθμης με κιμωλία', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 5, 34),
  ('tools', 'TLS-2026-035', 'Μεταλλική γωνία 30 cm', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 6, 35),
  ('tools', 'TLS-2026-036', 'Πιστόλι σιλικόνης επαγγελματικό', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 8, 36),
  ('tools', 'TLS-2026-037', 'Πιστόλι θερμοκόλλησης (σιλικόνης)', NULL, 'ΟΜΑΔΑ Δ — ΦΙΝΙΡΙΣΜΑΤΟΣ & ΜΕΤΡΗΣΗΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 12, 37),
  ('tools', 'TLS-2026-038', 'Τρυπάνι μετάλλου HSS Φ6 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512910-4', '—', NULL, false, NULL, 1, 38),
  ('tools', 'TLS-2026-039', 'Τρυπάνι μετάλλου HSS Φ10 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512910-4', '—', NULL, false, NULL, 2.5, 39),
  ('tools', 'TLS-2026-040', 'Σετ τρυπάνια μετάλλου HSS (19 τεμ)', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512910-4', '—', NULL, false, NULL, 14, 40),
  ('tools', 'TLS-2026-041', 'Τρυπάνι δομικών (πέτρας) Φ8×120 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512910-4', '—', NULL, false, NULL, 1.2, 41),
  ('tools', 'TLS-2026-042', 'Τρυπάνι κρουστικό SDS-plus Φ12×160 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512910-4', '—', NULL, false, NULL, 4.5, 42),
  ('tools', 'TLS-2026-043', 'Τρυπάνι ξύλου Φ8 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512910-4', '—', NULL, false, NULL, 1, 43),
  ('tools', 'TLS-2026-044', 'Ποτηροτρύπανο (διαμαντέ/μετάλλου) Φ50 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512900-1', '—', NULL, false, NULL, 9, 44),
  ('tools', 'TLS-2026-045', 'Σετ μύτες κατσαβιδιού (bits) PH2/PZ2 (10 τεμ)', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512900-1', '—', NULL, false, NULL, 4, 45),
  ('tools', 'TLS-2026-046', 'Καρυδάκι-μύτη μαγνητικό 8 mm', NULL, 'ΟΜΑΔΑ Ε — ΤΡΥΠΑΝΙΑ & ΜΥΤΕΣ (ΑΞΕΣΟΥΑΡ ΗΛΕΚΤΡΟΕΡΓΑΛΕΙΩΝ)', 'τεμ', '44512900-1', '—', NULL, false, NULL, 2, 46),
  ('tools', 'TLS-2026-047', 'Δίσκος κοπής μετάλλου/inox Φ115×1,0 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ 12413', NULL, false, NULL, 0.8, 47),
  ('tools', 'TLS-2026-048', 'Δίσκος κοπής μετάλλου Φ230×2,0 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ 12413', NULL, false, NULL, 1.5, 48),
  ('tools', 'TLS-2026-049', 'Δίσκος λείανσης μετάλλου Φ115×6 mm', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ 12413', NULL, false, NULL, 1.5, 49),
  ('tools', 'TLS-2026-050', 'Διαμαντόδισκος κοπής δομικών/πέτρας Φ115', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ 13236', NULL, false, NULL, 5, 50),
  ('tools', 'TLS-2026-051', 'Διαμαντόδισκος κοπής πλακιδίων Φ115', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ 13236', NULL, false, NULL, 6, 51),
  ('tools', 'TLS-2026-052', 'Δίσκος λείανσης πτυχωτός (flap) Φ115', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ 13743', NULL, false, NULL, 2, 52),
  ('tools', 'TLS-2026-053', 'Γυαλόχαρτο φύλλο (Νο 80/120/220)', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'τεμ', '14810000-2', 'ΕΛΟΤ ΕΝ ISO 6344', NULL, false, NULL, 0.4, 53),
  ('tools', 'TLS-2026-054', 'Σμυριδόπανο σε ρολό', NULL, 'ΟΜΑΔΑ ΣΤ — ΛΕΙΑΝΤΙΚΑ & ΔΙΣΚΟΙ (ΑΝΑΛΩΣΙΜΑ)', 'm', '14810000-2', 'ΕΛΟΤ ΕΝ ISO 6344', NULL, false, NULL, 2, 54),
  ('tools', 'TLS-2026-055', 'Πριονόλαμα σπαθόσεγας μετάλλου (5 τεμ)', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '44512900-1', '—', NULL, false, NULL, 7, 55),
  ('tools', 'TLS-2026-056', 'Πριονόλαμα σέγας ξύλου (5 τεμ)', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '44512900-1', '—', NULL, false, NULL, 5, 56),
  ('tools', 'TLS-2026-057', 'Ανταλλακτικές λάμες cutter 18 mm (10 τεμ)', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 2, 57),
  ('tools', 'TLS-2026-058', 'Ράβδοι θερμοκόλλησης σιλικόνης Φ11 mm', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'kg', '44831100-5', '—', NULL, false, NULL, 6, 58),
  ('tools', 'TLS-2026-059', 'Αντισκωριακό/λιπαντικό σπρέι πολλαπλών χρήσεων, 400 ml', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '24951000-5', '—', NULL, false, NULL, 4.5, 59),
  ('tools', 'TLS-2026-060', 'Μετρητική μεζούρα τροχού (οδόμετρο χειρός)', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '44512000-2', '—', NULL, false, NULL, 45, 60),
  ('tools', 'TLS-2026-061', 'Εργαλειοθήκη πλαστική 20"', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '44512930-0', '—', NULL, false, NULL, 18, 61),
  ('tools', 'TLS-2026-062', 'Σκάλα αλουμινίου διπλή (2×7 σκαλιά)', NULL, 'ΟΜΑΔΑ Ζ — ΑΝΑΛΩΣΙΜΑ ΕΡΓΑΛΕΙΩΝ & ΛΟΙΠΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '44423200-3', 'ΕΛΟΤ ΕΝ 131', NULL, false, NULL, 75, 62),
  ('urban_equipment', 'URB-2026-001', 'Παγκάκι (καθιστικό) μεταλλικό με ξύλινες δοκίδες, μήκους 1,8 m', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 220, 1),
  ('urban_equipment', 'URB-2026-002', 'Παγκάκι σκυροδέματος με ξύλινη επιφάνεια καθίσματος', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 280, 2),
  ('urban_equipment', 'URB-2026-003', 'Παγκάκι χωρίς πλάτη (διπλής όψης)', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 180, 3),
  ('urban_equipment', 'URB-2026-004', 'Καθιστικό τύπου κύβου/εξέδρας', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 150, 4),
  ('urban_equipment', 'URB-2026-005', 'Τραπεζοπάγκος πικ-νικ (σετ τραπέζι με πάγκους)', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 320, 5),
  ('urban_equipment', 'URB-2026-006', 'Μεταλλική πέργκολα/σκίαστρο (μονάδα)', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 900, 6),
  ('urban_equipment', 'URB-2026-007', 'Κρουνός/βρύση πλατείας πόσιμου νερού', NULL, 'ΟΜΑΔΑ Α — ΚΑΘΙΣΤΙΚΑ & ΕΞΟΠΛΙΣΜΟΣ ΑΝΑΨΥΧΗΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 350, 7),
  ('urban_equipment', 'URB-2026-008', 'Καλάθι απορριμμάτων μεταλλικό (ιστού/τοίχου) 50 L', NULL, 'ΟΜΑΔΑ Β — ΑΠΟΡΡΙΜΜΑΤΑ & ΑΣΤΙΚΟ ΠΡΑΣΙΝΟ', 'τεμ', '34928480-6', '—', NULL, false, NULL, 90, 8),
  ('urban_equipment', 'URB-2026-009', 'Καλάθι απορριμμάτων με ξύλινη επένδυση 60 L', NULL, 'ΟΜΑΔΑ Β — ΑΠΟΡΡΙΜΜΑΤΑ & ΑΣΤΙΚΟ ΠΡΑΣΙΝΟ', 'τεμ', '34928480-6', '—', NULL, false, NULL, 140, 9),
  ('urban_equipment', 'URB-2026-010', 'Κάδος απορριμμάτων πλαστικός με ρόδες 240 L', NULL, 'ΟΜΑΔΑ Β — ΑΠΟΡΡΙΜΜΑΤΑ & ΑΣΤΙΚΟ ΠΡΑΣΙΝΟ', 'τεμ', '34928480-6', 'ΕΛΟΤ ΕΝ 840', NULL, false, NULL, 45, 10),
  ('urban_equipment', 'URB-2026-011', 'Κάδος απορριμμάτων 1.100 L (μεταλλικός/πλαστικός)', NULL, 'ΟΜΑΔΑ Β — ΑΠΟΡΡΙΜΜΑΤΑ & ΑΣΤΙΚΟ ΠΡΑΣΙΝΟ', 'τεμ', '34928480-6', 'ΕΛΟΤ ΕΝ 840', NULL, false, NULL, 220, 11),
  ('urban_equipment', 'URB-2026-012', 'Ζαρντινιέρα πλατείας (μεταλλική/σκυροδέματος)', NULL, 'ΟΜΑΔΑ Β — ΑΠΟΡΡΙΜΜΑΤΑ & ΑΣΤΙΚΟ ΠΡΑΣΙΝΟ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 120, 12),
  ('urban_equipment', 'URB-2026-013', 'Σχάρα προστασίας κορμού δέντρου (μεταλλική)', NULL, 'ΟΜΑΔΑ Β — ΑΠΟΡΡΙΜΜΑΤΑ & ΑΣΤΙΚΟ ΠΡΑΣΙΝΟ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 90, 13),
  ('urban_equipment', 'URB-2026-014', 'Κολωνάκι (εμπόδιο) σταθερό μεταλλικό Φ90 mm', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'τεμ', '34928450-7', '—', NULL, false, NULL, 45, 14),
  ('urban_equipment', 'URB-2026-015', 'Κολωνάκι αποσπώμενο με κλειδαριά', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'τεμ', '34928450-7', '—', NULL, false, NULL, 65, 15),
  ('urban_equipment', 'URB-2026-016', 'Κολωνάκι ανακλινόμενο (πτυσσόμενο)', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'τεμ', '34928450-7', '—', NULL, false, NULL, 85, 16),
  ('urban_equipment', 'URB-2026-017', 'Εύκαμπτο πλαστικό κολωνάκι (επαναφερόμενο)', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'τεμ', '34928450-7', '—', NULL, false, NULL, 18, 17),
  ('urban_equipment', 'URB-2026-018', 'Κιγκλίδωμα προστασίας πεζών μεταλλικό, ανά m', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'm', '34928320-7', 'ΕΛΟΤ ΕΝ ISO 1461', NULL, false, NULL, 55, 18),
  ('urban_equipment', 'URB-2026-019', 'Αλυσίδα οριοθέτησης μεταξύ κολωνακίων, ανά m', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'm', '34928450-7', '—', NULL, false, NULL, 8, 19),
  ('urban_equipment', 'URB-2026-020', 'Προστατευτικό εμπόδιο στάθμευσης ποδηλάτων/μηχανών (τύπου U)', NULL, 'ΟΜΑΔΑ Γ — ΟΡΙΟΘΕΤΗΣΗ & ΠΡΟΣΤΑΣΙΑ ΠΕΖΩΝ', 'τεμ', '34928450-7', '—', NULL, false, NULL, 40, 20),
  ('urban_equipment', 'URB-2026-021', 'Κούνια παιδικής χαράς διθέσια (μεταλλική)', NULL, 'ΟΜΑΔΑ Δ — ΠΑΙΔΙΚΕΣ ΧΑΡΕΣ & ΥΠΑΙΘΡΙΑ ΑΘΛΗΣΗ', 'τεμ', '37535200-9', 'ΕΛΟΤ ΕΝ 1176', NULL, false, NULL, 650, 21),
  ('urban_equipment', 'URB-2026-022', 'Τσουλήθρα παιδικής χαράς', NULL, 'ΟΜΑΔΑ Δ — ΠΑΙΔΙΚΕΣ ΧΑΡΕΣ & ΥΠΑΙΘΡΙΑ ΑΘΛΗΣΗ', 'τεμ', '37535200-9', 'ΕΛΟΤ ΕΝ 1176', NULL, false, NULL, 550, 22),
  ('urban_equipment', 'URB-2026-023', 'Σύνθετο όργανο παιδικής χαράς (πυργίσκος με δραστηριότητες)', NULL, 'ΟΜΑΔΑ Δ — ΠΑΙΔΙΚΕΣ ΧΑΡΕΣ & ΥΠΑΙΘΡΙΑ ΑΘΛΗΣΗ', 'τεμ', '37535200-9', 'ΕΛΟΤ ΕΝ 1176', NULL, false, NULL, 2500, 23),
  ('urban_equipment', 'URB-2026-024', 'Ελαστικό δάπεδο ασφαλείας παιδικής χαράς (πλάκα), ανά m²', NULL, 'ΟΜΑΔΑ Δ — ΠΑΙΔΙΚΕΣ ΧΑΡΕΣ & ΥΠΑΙΘΡΙΑ ΑΘΛΗΣΗ', 'm²', '37535200-9', 'ΕΛΟΤ ΕΝ 1177', NULL, false, NULL, 45, 24),
  ('urban_equipment', 'URB-2026-025', 'Όργανο υπαίθριας άθλησης ενηλίκων', NULL, 'ΟΜΑΔΑ Δ — ΠΑΙΔΙΚΕΣ ΧΑΡΕΣ & ΥΠΑΙΘΡΙΑ ΑΘΛΗΣΗ', 'τεμ', '37440000-4', 'ΕΛΟΤ ΕΝ 16630', NULL, false, NULL, 700, 25),
  ('urban_equipment', 'URB-2026-026', 'Ποδηλατοστάτης μεταλλικός (πολλαπλών θέσεων)', NULL, 'ΟΜΑΔΑ Ε — ΛΟΙΠΟΣ ΑΣΤΙΚΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 120, 26),
  ('urban_equipment', 'URB-2026-027', 'Στέγαστρο στάσης αστικής συγκοινωνίας', NULL, 'ΟΜΑΔΑ Ε — ΛΟΙΠΟΣ ΑΣΤΙΚΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 1800, 27),
  ('urban_equipment', 'URB-2026-028', 'Πινακίδα πληροφόρησης πάρκου/πεζοδρόμου', NULL, 'ΟΜΑΔΑ Ε — ΛΟΙΠΟΣ ΑΣΤΙΚΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '34928470-3', '—', NULL, false, NULL, 120, 28),
  ('urban_equipment', 'URB-2026-029', 'Ιστός σημαίας αλουμινίου ύψους 6 m', NULL, 'ΟΜΑΔΑ Ε — ΛΟΙΠΟΣ ΑΣΤΙΚΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'τεμ', '34928400-2', '—', NULL, false, NULL, 180, 29),
  ('urban_equipment', 'URB-2026-030', 'Ελαστικός μειωτής ταχύτητας (σαμαράκι), ανά m', NULL, 'ΟΜΑΔΑ Ε — ΛΟΙΠΟΣ ΑΣΤΙΚΟΣ ΕΞΟΠΛΙΣΜΟΣ', 'm', '34928400-2', '—', NULL, false, NULL, 60, 30)
),
groups as (
  select id, code
  from public.procurement_groups
  where code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[])
)
insert into public.materials (
  group_id, code, name, short_name, subcategory, unit, cpv,
  standards, technical_specs, ce_required, notes_for_tender,
  default_unit_price, sort_order, is_active
)
select
  g.id, s.material_code, s.name, s.short_name, s.subcategory, s.unit, s.cpv,
  s.standards, s.technical_specs, s.ce_required, s.notes_for_tender,
  s.default_unit_price, s.sort_order, true
from src s
join groups g on g.code = s.group_code;

-- Τελικοί αυστηροί έλεγχοι πριν από το COMMIT.
do $$
declare
  r record;
  v_actual integer;
  v_total integer;
  v_duplicates integer;
  v_bad_rows integer;
begin
  for r in
    select *
    from (values
  ('electrical', 231),
  ('building', 100),
  ('aggregates', 8),
  ('asphalt', 15),
  ('hardware', 60),
  ('air_conditioning', 20),
  ('plumbing', 100),
  ('paint', 62),
  ('signage', 100),
  ('wood', 50),
  ('glass', 50),
  ('ppe', 30),
  ('tools', 62),
  ('urban_equipment', 30)
    ) as e(group_code, expected_count)
  loop
    select count(*)
    into v_actual
    from public.materials m
    join public.procurement_groups pg on pg.id = m.group_id
    where pg.code = r.group_code
      and m.is_active = true;

    if v_actual <> r.expected_count then
      raise exception
        'ΑΚΥΡΩΣΗ: ομάδα %, αναμένονταν % είδη, αλλά εισήχθησαν %.',
        r.group_code, r.expected_count, v_actual;
    end if;
  end loop;

  select count(*)
  into v_total
  from public.materials m
  join public.procurement_groups pg on pg.id = m.group_id
  where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[])
    and m.is_active = true;

  if v_total <> 918 then
    raise exception 'ΑΚΥΡΩΣΗ: αναμένονταν συνολικά 918 είδη, αλλά βρέθηκαν %.', v_total;
  end if;

  select count(*)
  into v_duplicates
  from (
    select m.group_id, lower(trim(m.name)) as n, trim(m.unit) as u
    from public.materials m
    join public.procurement_groups pg on pg.id = m.group_id
    where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[])
    group by m.group_id, lower(trim(m.name)), trim(m.unit)
    having count(*) > 1
  ) d;

  if v_duplicates <> 0 then
    raise exception 'ΑΚΥΡΩΣΗ: εντοπίστηκαν % διπλοεγγραφές περιγραφής/μονάδας.', v_duplicates;
  end if;

  select count(*)
  into v_bad_rows
  from public.materials m
  join public.procurement_groups pg on pg.id = m.group_id
  where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[])
    and (
      nullif(trim(m.name), '') is null
      or nullif(trim(m.unit), '') is null
      or nullif(trim(m.cpv), '') is null
      or m.default_unit_price is null
      or m.default_unit_price < 0
    );

  if v_bad_rows <> 0 then
    raise exception 'ΑΚΥΡΩΣΗ: εντοπίστηκαν % ελλιπείς ή μη έγκυρες εγγραφές.', v_bad_rows;
  end if;

  raise notice 'Η πλήρης αντικατάσταση ολοκληρώθηκε επιτυχώς.';
  raise notice 'Εισήχθησαν 918 είδη σε 14 ομάδες.';
  raise notice 'Οι παλιές ποσότητες διαγράφηκαν και τα δελτία επανήλθαν σε draft.';
end
$$;

commit;

-- Αναμενόμενο τελικό αποτέλεσμα: 14 γραμμές και συνολικό πλήθος 918.
select
  pg.sort_order,
  pg.code,
  pg.name,
  count(m.id) filter (where m.is_active) as ενεργά_είδη
from public.procurement_groups pg
left join public.materials m on m.group_id = pg.id
where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[])
group by pg.id, pg.sort_order, pg.code, pg.name
order by pg.sort_order;

select
  count(*) as συνολικά_ενεργά_είδη_νέου_καταλόγου
from public.materials m
join public.procurement_groups pg on pg.id = m.group_id
where pg.code = any(array['electrical','building','aggregates','asphalt','hardware','air_conditioning','plumbing','paint','signage','wood','glass','ppe','tools','urban_equipment']::text[])
  and m.is_active = true;

-- ============================================================================
-- ΜΕΡΟΣ Δ — Υποσύστημα «Δελτία Υλικού» v36
-- ============================================================================

begin;

create table if not exists public.mo_suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  afm text,
  email text,
  viber_phone text,
  phone text,
  address text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null
    default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mo_contracts (
  id uuid primary key default gen_random_uuid(),
  supplier_id uuid not null
    references public.mo_suppliers(id) on delete restrict,
  title text not null,
  adam text,
  protocol_no text,
  cpv text,
  start_date date,
  end_date date,
  total_amount numeric(14,2) not null default 0
    check (total_amount >= 0),
  vat_rate numeric(5,2) not null default 24
    check (vat_rate >= 0 and vat_rate <= 100),
  active boolean not null default true,
  source_study_id uuid
    references public.locked_studies(id) on delete set null,
  municipal_unit_id smallint
    references public.municipal_units(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null
    default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_mo_contracts_source_study
  on public.mo_contracts(source_study_id)
  where source_study_id is not null;

create table if not exists public.mo_contract_items (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null
    references public.mo_contracts(id) on delete cascade,
  code text,
  description text not null,
  unit text,
  unit_price numeric(14,4) not null default 0
    check (unit_price >= 0),
  cpv text,
  contract_qty numeric(14,3)
    check (contract_qty is null or contract_qty >= 0),
  material_id uuid
    references public.materials(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mo_receivers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  role text,
  email text,
  viber_phone text,
  phone text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null
    default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mo_projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  code text,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null
    default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mo_orders (
  id uuid primary key default gen_random_uuid(),
  order_no text unique,
  order_date date not null default current_date,
  supplier_id uuid
    references public.mo_suppliers(id) on delete set null,
  contract_id uuid
    references public.mo_contracts(id) on delete restrict,
  receiver_id uuid
    references public.mo_receivers(id) on delete set null,
  project_id uuid
    references public.mo_projects(id) on delete set null,
  usage_location text,
  notes text,
  vat_rate numeric(5,2) not null default 24
    check (vat_rate >= 0 and vat_rate <= 100),
  subtotal numeric(14,2) not null default 0
    check (subtotal >= 0),
  vat numeric(14,2) not null default 0
    check (vat >= 0),
  total numeric(14,2) not null default 0
    check (total >= 0),
  status text not null default 'draft'
    check (status in ('draft', 'issued', 'sent', 'received', 'cancelled')),
  sent_at date,
  received_at date,
  created_by uuid references auth.users(id) on delete set null
    default auth.uid(),
  municipal_unit_id smallint not null
    references public.municipal_units(id) on delete restrict,
  study_id uuid
    references public.locked_studies(id) on delete restrict,
  issued_at timestamptz,
  issued_by uuid
    references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mo_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null
    references public.mo_orders(id) on delete cascade,
  description text not null,
  unit text,
  quantity numeric(14,3) not null default 0
    check (quantity >= 0),
  unit_price numeric(14,4) not null default 0
    check (unit_price >= 0),
  line_total numeric(14,2) not null default 0
    check (line_total >= 0),
  contract_item_id uuid
    references public.mo_contract_items(id) on delete set null,
  is_custom boolean not null default false,
  mapping jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.mo_counters (
  scope text primary key,
  value integer not null default 0
    check (value >= 0)
);

create index if not exists idx_mo_suppliers_name
  on public.mo_suppliers(lower(name));
create index if not exists idx_mo_contracts_supplier
  on public.mo_contracts(supplier_id);
create index if not exists idx_mo_contracts_unit
  on public.mo_contracts(municipal_unit_id);
create index if not exists idx_mo_contract_items_contract
  on public.mo_contract_items(contract_id);
create index if not exists idx_mo_contract_items_material
  on public.mo_contract_items(material_id);
create index if not exists idx_mo_orders_contract
  on public.mo_orders(contract_id);
create index if not exists idx_mo_orders_supplier
  on public.mo_orders(supplier_id);
create index if not exists idx_mo_orders_status
  on public.mo_orders(status);
create index if not exists idx_mo_orders_unit
  on public.mo_orders(municipal_unit_id);
create index if not exists idx_mo_orders_study
  on public.mo_orders(study_id);
create index if not exists idx_mo_order_items_order
  on public.mo_order_items(order_id);
create index if not exists idx_mo_order_items_contract_item
  on public.mo_order_items(contract_item_id);

drop trigger if exists trg_mo_suppliers_updated_at on public.mo_suppliers;
create trigger trg_mo_suppliers_updated_at
before update on public.mo_suppliers
for each row execute function public.set_updated_at();

drop trigger if exists trg_mo_contracts_updated_at on public.mo_contracts;
create trigger trg_mo_contracts_updated_at
before update on public.mo_contracts
for each row execute function public.set_updated_at();

drop trigger if exists trg_mo_contract_items_updated_at
  on public.mo_contract_items;
create trigger trg_mo_contract_items_updated_at
before update on public.mo_contract_items
for each row execute function public.set_updated_at();

drop trigger if exists trg_mo_receivers_updated_at on public.mo_receivers;
create trigger trg_mo_receivers_updated_at
before update on public.mo_receivers
for each row execute function public.set_updated_at();

drop trigger if exists trg_mo_projects_updated_at on public.mo_projects;
create trigger trg_mo_projects_updated_at
before update on public.mo_projects
for each row execute function public.set_updated_at();

drop trigger if exists trg_mo_orders_updated_at on public.mo_orders;
create trigger trg_mo_orders_updated_at
before update on public.mo_orders
for each row execute function public.set_updated_at();

drop trigger if exists trg_mo_order_items_updated_at
  on public.mo_order_items;
create trigger trg_mo_order_items_updated_at
before update on public.mo_order_items
for each row execute function public.set_updated_at();

create or replace function public.mo_current_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select public.current_user_role()::text;
$$;

create or replace function public.mo_current_unit_id()
returns smallint
language sql
stable
security definer
set search_path = public
as $$
  select public.current_user_unit_id();
$$;

create or replace function public.mo_can_read_unit(p_unit_id smallint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.mo_current_role() in ('admin', 'central', 'viewer')
    or (
      public.mo_current_role() = 'unit_user'
      and public.mo_current_unit_id() = p_unit_id
    ),
    false
  );
$$;

create or replace function public.mo_can_manage_unit(p_unit_id smallint)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    public.mo_current_role() in ('admin', 'central')
    or (
      public.mo_current_role() = 'unit_user'
      and public.mo_current_unit_id() = p_unit_id
    ),
    false
  );
$$;

create or replace function public.mo_next_order_number(p_scope text)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_value integer;
begin
  if auth.uid() is null or public.mo_current_role() is null then
    raise exception 'Απαιτείται σύνδεση.'
      using errcode = '42501';
  end if;

  if nullif(trim(p_scope), '') is null then
    raise exception 'Το πεδίο αρίθμησης είναι υποχρεωτικό.'
      using errcode = '22023';
  end if;

  insert into public.mo_counters(scope, value)
  values (p_scope, 1)
  on conflict (scope)
  do update set value = public.mo_counters.value + 1
  returning value into v_value;

  return v_value;
end;
$$;

alter table public.mo_suppliers enable row level security;
alter table public.mo_contracts enable row level security;
alter table public.mo_contract_items enable row level security;
alter table public.mo_receivers enable row level security;
alter table public.mo_projects enable row level security;
alter table public.mo_orders enable row level security;
alter table public.mo_order_items enable row level security;
alter table public.mo_counters enable row level security;

-- Καθαρισμός τυχόν παλαιών καθολικά επιτρεπτικών policies.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'mo_suppliers', 'mo_contracts', 'mo_contract_items',
    'mo_receivers', 'mo_projects', 'mo_orders',
    'mo_order_items', 'mo_counters'
  ]
  loop
    execute format(
      'drop policy if exists %I on public.%I',
      'auth_all_' || v_table,
      v_table
    );
  end loop;
end $$;

-- Προμηθευτές: όλοι διαβάζουν. Οι χρήστες Δ.Ε. μπορούν να δημιουργούν
-- τον προμηθευτή κλειδωμένης μελέτης, αλλά μόνο admin/central τον αλλάζουν.
drop policy if exists mo_suppliers_select on public.mo_suppliers;
create policy mo_suppliers_select
on public.mo_suppliers for select
to authenticated
using (true);

drop policy if exists mo_suppliers_insert on public.mo_suppliers;
create policy mo_suppliers_insert
on public.mo_suppliers for insert
to authenticated
with check (
  public.mo_current_role() in ('admin', 'central', 'unit_user')
  and created_by = auth.uid()
);

drop policy if exists mo_suppliers_update on public.mo_suppliers;
create policy mo_suppliers_update
on public.mo_suppliers for update
to authenticated
using (public.mo_current_role() in ('admin', 'central'))
with check (public.mo_current_role() in ('admin', 'central'));

drop policy if exists mo_suppliers_delete on public.mo_suppliers;
create policy mo_suppliers_delete
on public.mo_suppliers for delete
to authenticated
using (public.mo_current_role() in ('admin', 'central'));

-- Συμβάσεις και είδη συμβάσεων.
drop policy if exists mo_contracts_select on public.mo_contracts;
create policy mo_contracts_select
on public.mo_contracts for select
to authenticated
using (
  public.mo_current_role() in ('admin', 'central', 'viewer')
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
  )
);

drop policy if exists mo_contracts_insert on public.mo_contracts;
create policy mo_contracts_insert
on public.mo_contracts for insert
to authenticated
with check (
  (
    public.mo_current_role() in ('admin', 'central')
    or (
      public.mo_current_role() = 'unit_user'
      and municipal_unit_id = public.mo_current_unit_id()
    )
  )
  and created_by = auth.uid()
);

drop policy if exists mo_contracts_update on public.mo_contracts;
create policy mo_contracts_update
on public.mo_contracts for update
to authenticated
using (
  public.mo_current_role() in ('admin', 'central')
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
  )
)
with check (
  public.mo_current_role() in ('admin', 'central')
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
  )
);

drop policy if exists mo_contracts_delete on public.mo_contracts;
create policy mo_contracts_delete
on public.mo_contracts for delete
to authenticated
using (
  public.mo_current_role() in ('admin', 'central')
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
  )
);

drop policy if exists mo_contract_items_select
  on public.mo_contract_items;
create policy mo_contract_items_select
on public.mo_contract_items for select
to authenticated
using (
  exists (
    select 1
    from public.mo_contracts c
    where c.id = contract_id
      and (
        public.mo_current_role() in ('admin', 'central', 'viewer')
        or (
          public.mo_current_role() = 'unit_user'
          and c.municipal_unit_id = public.mo_current_unit_id()
        )
      )
  )
);

drop policy if exists mo_contract_items_insert
  on public.mo_contract_items;
create policy mo_contract_items_insert
on public.mo_contract_items for insert
to authenticated
with check (
  exists (
    select 1
    from public.mo_contracts c
    where c.id = contract_id
      and public.mo_can_manage_unit(c.municipal_unit_id)
  )
);

drop policy if exists mo_contract_items_update
  on public.mo_contract_items;
create policy mo_contract_items_update
on public.mo_contract_items for update
to authenticated
using (
  exists (
    select 1
    from public.mo_contracts c
    where c.id = contract_id
      and public.mo_can_manage_unit(c.municipal_unit_id)
  )
)
with check (
  exists (
    select 1
    from public.mo_contracts c
    where c.id = contract_id
      and public.mo_can_manage_unit(c.municipal_unit_id)
  )
);

drop policy if exists mo_contract_items_delete
  on public.mo_contract_items;
create policy mo_contract_items_delete
on public.mo_contract_items for delete
to authenticated
using (
  exists (
    select 1
    from public.mo_contracts c
    where c.id = contract_id
      and public.mo_can_manage_unit(c.municipal_unit_id)
  )
);

-- Παραλαμβάνοντες και έργα/χρήσεις.
drop policy if exists mo_receivers_select on public.mo_receivers;
create policy mo_receivers_select
on public.mo_receivers for select
to authenticated
using (true);

drop policy if exists mo_receivers_manage on public.mo_receivers;
create policy mo_receivers_manage
on public.mo_receivers for all
to authenticated
using (public.mo_current_role() in ('admin', 'central'))
with check (public.mo_current_role() in ('admin', 'central'));

drop policy if exists mo_projects_select on public.mo_projects;
create policy mo_projects_select
on public.mo_projects for select
to authenticated
using (true);

drop policy if exists mo_projects_manage on public.mo_projects;
create policy mo_projects_manage
on public.mo_projects for all
to authenticated
using (public.mo_current_role() in ('admin', 'central'))
with check (public.mo_current_role() in ('admin', 'central'));

-- Δελτία.
drop policy if exists mo_orders_select on public.mo_orders;
create policy mo_orders_select
on public.mo_orders for select
to authenticated
using (public.mo_can_read_unit(municipal_unit_id));

drop policy if exists mo_orders_insert on public.mo_orders;
create policy mo_orders_insert
on public.mo_orders for insert
to authenticated
with check (
  public.mo_can_manage_unit(municipal_unit_id)
  and created_by = auth.uid()
);

drop policy if exists mo_orders_update on public.mo_orders;
create policy mo_orders_update
on public.mo_orders for update
to authenticated
using (
  public.mo_current_role() in ('admin', 'central')
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
    and status = 'draft'
  )
)
with check (
  public.mo_current_role() in ('admin', 'central')
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
  )
);

drop policy if exists mo_orders_delete on public.mo_orders;
create policy mo_orders_delete
on public.mo_orders for delete
to authenticated
using (
  public.mo_current_role() = 'admin'
  or (
    public.mo_current_role() = 'central'
    and status = 'draft'
  )
  or (
    public.mo_current_role() = 'unit_user'
    and municipal_unit_id = public.mo_current_unit_id()
    and status = 'draft'
  )
);

drop policy if exists mo_order_items_select
  on public.mo_order_items;
create policy mo_order_items_select
on public.mo_order_items for select
to authenticated
using (
  exists (
    select 1
    from public.mo_orders o
    where o.id = order_id
      and public.mo_can_read_unit(o.municipal_unit_id)
  )
);

drop policy if exists mo_order_items_insert
  on public.mo_order_items;
create policy mo_order_items_insert
on public.mo_order_items for insert
to authenticated
with check (
  exists (
    select 1
    from public.mo_orders o
    where o.id = order_id
      and (
        public.mo_current_role() in ('admin', 'central')
        or (
          public.mo_current_role() = 'unit_user'
          and o.municipal_unit_id = public.mo_current_unit_id()
          and o.status = 'draft'
        )
      )
  )
);

drop policy if exists mo_order_items_update
  on public.mo_order_items;
create policy mo_order_items_update
on public.mo_order_items for update
to authenticated
using (
  exists (
    select 1
    from public.mo_orders o
    where o.id = order_id
      and (
        public.mo_current_role() in ('admin', 'central')
        or (
          public.mo_current_role() = 'unit_user'
          and o.municipal_unit_id = public.mo_current_unit_id()
          and o.status = 'draft'
        )
      )
  )
)
with check (
  exists (
    select 1
    from public.mo_orders o
    where o.id = order_id
      and (
        public.mo_current_role() in ('admin', 'central')
        or (
          public.mo_current_role() = 'unit_user'
          and o.municipal_unit_id = public.mo_current_unit_id()
          and o.status = 'draft'
        )
      )
  )
);

drop policy if exists mo_order_items_delete
  on public.mo_order_items;
create policy mo_order_items_delete
on public.mo_order_items for delete
to authenticated
using (
  exists (
    select 1
    from public.mo_orders o
    where o.id = order_id
      and (
        public.mo_current_role() in ('admin', 'central')
        or (
          public.mo_current_role() = 'unit_user'
          and o.municipal_unit_id = public.mo_current_unit_id()
          and o.status = 'draft'
        )
      )
  )
);

drop policy if exists mo_counters_select on public.mo_counters;
create policy mo_counters_select
on public.mo_counters for select
to authenticated
using (true);

-- Ρητά grants για το κλειστό automatic exposure.
revoke all on table
  public.mo_suppliers,
  public.mo_contracts,
  public.mo_contract_items,
  public.mo_receivers,
  public.mo_projects,
  public.mo_orders,
  public.mo_order_items,
  public.mo_counters
from anon;

grant select, insert, update, delete on table
  public.mo_suppliers,
  public.mo_contracts,
  public.mo_contract_items,
  public.mo_receivers,
  public.mo_projects,
  public.mo_orders,
  public.mo_order_items
to authenticated;

grant select on table public.mo_counters to authenticated;

revoke all on function public.mo_current_role()
  from public, anon;
revoke all on function public.mo_current_unit_id()
  from public, anon;
revoke all on function public.mo_can_read_unit(smallint)
  from public, anon;
revoke all on function public.mo_can_manage_unit(smallint)
  from public, anon;
revoke all on function public.mo_next_order_number(text)
  from public, anon;

grant execute on function public.mo_current_role()
  to authenticated;
grant execute on function public.mo_current_unit_id()
  to authenticated;
grant execute on function public.mo_can_read_unit(smallint)
  to authenticated;
grant execute on function public.mo_can_manage_unit(smallint)
  to authenticated;
grant execute on function public.mo_next_order_number(text)
  to authenticated;

comment on column public.mo_orders.study_id is
  'Κλειδωμένη μελέτη από την οποία εκδόθηκε το δελτίο.';
comment on column public.mo_orders.municipal_unit_id is
  'Δημοτική Ενότητα στην οποία χρεώνεται το δελτίο.';
comment on column public.mo_order_items.mapping is
  'Αντιστοίχιση είδους εκτός τιμολογίου: [{contract_item_id, qty}].';

commit;

-- ============================================================================
-- ΜΕΡΟΣ Ε — Τελικός έλεγχος εγκατάστασης
-- ============================================================================

do $$
declare
  v_missing_tables text[];
  v_units integer;
  v_groups integer;
  v_materials integer;
  v_service_groups integer;
  v_bad_rls integer;
  v_legacy_policies integer;
  v_has_central boolean;
begin
  select array_agg(required_table order by required_table)
  into v_missing_tables
  from (
    values
      ('municipal_units'),
      ('procurement_groups'),
      ('profiles'),
      ('materials'),
      ('unit_requests'),
      ('request_lines'),
      ('saved_versions'),
      ('export_jobs'),
      ('locked_studies'),
      ('tender_overrides'),
      ('mo_suppliers'),
      ('mo_contracts'),
      ('mo_contract_items'),
      ('mo_receivers'),
      ('mo_projects'),
      ('mo_orders'),
      ('mo_order_items'),
      ('mo_counters')
  ) as required(required_table)
  where to_regclass('public.' || required_table) is null;

  if v_missing_tables is not null then
    raise exception 'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: λείπουν οι πίνακες %.',
      array_to_string(v_missing_tables, ', ');
  end if;

  select count(*)
  into v_units
  from public.municipal_units
  where id between 1 and 11
    and is_active = true;

  if v_units <> 11 then
    raise exception
      'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: αναμένονταν 11 ενεργές μονάδες (10 Δ.Ε. + Δήμος Ρόδου), βρέθηκαν %.',
      v_units;
  end if;

  select count(*)
  into v_groups
  from public.procurement_groups
  where code = any(array[
    'electrical','building','aggregates','asphalt','hardware',
    'air_conditioning','plumbing','paint','signage','wood','glass',
    'ppe','tools','urban_equipment'
  ]::text[])
    and domain = 'procurement'
    and is_active = true;

  if v_groups <> 14 then
    raise exception
      'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: αναμένονταν 14 ενεργές ομάδες προμηθειών, βρέθηκαν %.',
      v_groups;
  end if;

  select count(*)
  into v_materials
  from public.materials m
  join public.procurement_groups g on g.id = m.group_id
  where g.code = any(array[
    'electrical','building','aggregates','asphalt','hardware',
    'air_conditioning','plumbing','paint','signage','wood','glass',
    'ppe','tools','urban_equipment'
  ]::text[])
    and m.is_active = true;

  if v_materials <> 918 then
    raise exception
      'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: αναμένονταν 918 ενεργά είδη, βρέθηκαν %.',
      v_materials;
  end if;

  select count(*)
  into v_service_groups
  from public.procurement_groups
  where domain = 'service'
    and is_active = true;

  select count(*)
  into v_bad_rls
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = any(array[
      'municipal_units','procurement_groups','profiles','materials',
      'material_aliases','price_observations','unit_requests',
      'request_lines','saved_versions','export_jobs','locked_studies',
      'tender_overrides','mo_suppliers','mo_contracts',
      'mo_contract_items','mo_receivers','mo_projects','mo_orders',
      'mo_order_items','mo_counters'
    ]::text[])
    and c.relkind = 'r'
    and c.relrowsecurity = false;

  if v_bad_rls <> 0 then
    raise exception
      'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: % απαιτούμενοι πίνακες δεν έχουν ενεργό RLS.',
      v_bad_rls;
  end if;

  select count(*)
  into v_legacy_policies
  from pg_policies
  where schemaname = 'public'
    and policyname like 'auth_all_%';

  if v_legacy_policies <> 0 then
    raise exception
      'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: παραμένουν % καθολικά επιτρεπτικές auth_all_ policies.',
      v_legacy_policies;
  end if;

  select exists (
    select 1
    from pg_enum e
    join pg_type t on t.oid = e.enumtypid
    join pg_namespace n on n.oid = t.typnamespace
    where n.nspname = 'public'
      and t.typname = 'app_role'
      and e.enumlabel = 'central'
  )
  into v_has_central;

  if not v_has_central then
    raise exception
      'ΑΚΥΡΩΣΗ ΕΛΕΓΧΟΥ: λείπει ο ρόλος central.';
  end if;

  raise notice 'ΕΠΙΤΥΧΙΑ: εγκαταστάθηκαν 11 μονάδες, 14 ομάδες και 918 είδη.';
  raise notice 'ΕΠΙΤΥΧΙΑ: εγκαταστάθηκαν locked_studies, tender_overrides και όλοι οι mo_* πίνακες.';
  if v_service_groups = 0 then
    raise notice 'ΠΛΗΡΟΦΟΡΙΑ: δεν εισήχθη κατάλογος Υπηρεσιών, επειδή δεν περιλαμβανόταν στα δύο αρχεία πηγής.';
  else
    raise notice 'ΠΛΗΡΟΦΟΡΙΑ: ενεργές ομάδες Υπηρεσιών: %.', v_service_groups;
  end if;
end
$$;

select
  (select count(*) from public.municipal_units where is_active) as ενεργές_μονάδες,
  (select count(*) from public.procurement_groups
    where domain = 'procurement' and is_active) as ομάδες_προμηθειών,
  (select count(*) from public.procurement_groups
    where domain = 'service' and is_active) as ομάδες_υπηρεσιών,
  (select count(*) from public.materials where is_active) as ενεργά_είδη,
  (select count(*) from public.locked_studies) as κλειδωμένες_μελέτες,
  (select count(*) from public.mo_orders) as δελτία_υλικού;

-- ============================================================================
-- ΕΠΟΜΕΝΟ ΒΗΜΑ ΜΕΤΑ ΤΗΝ ΕΠΙΤΥΧΙΑ:
-- 1. Authentication -> Users -> Add user.
-- 2. Έπειτα ορίστε τον πρώτο administrator από το SQL Editor:
--
-- update public.profiles
-- set role = 'admin', municipal_unit_id = null
-- where email = 'ΤΟ_EMAIL_ΤΟΥ_ADMIN';
--
-- Για χρήστη Δημοτικής Ενότητας:
-- update public.profiles
-- set role = 'unit_user', municipal_unit_id = 4
-- where email = 'user@example.gr';
--
-- Για τον κεντρικό λογαριασμό Δήμου Ρόδου:
-- update public.profiles
-- set role = 'central', municipal_unit_id = 11
-- where email = 'central@example.gr';
-- ============================================================================
