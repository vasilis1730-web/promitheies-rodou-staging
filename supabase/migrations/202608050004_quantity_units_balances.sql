begin;

-- v36.3 / Βήμα 3
-- Κανόνες δεκαδικών ποσοτήτων ανά μονάδα μέτρησης και ενιαίος,
-- server-side υπολογισμός συμβατικών υπολοίπων και δελτίων.

create or replace function public.app_unit_key(p_unit text)
returns text
language sql
immutable
parallel safe
as $$
  select regexp_replace(
    translate(
      lower(btrim(coalesce(p_unit, ''))),
      'άέήίόύώϊΐϋΰ',
      'αεηιουωιιυυ'
    ),
    '[[:space:].·]+', '', 'g'
  )
$$;

create or replace function public.app_unit_default_scale(p_unit text)
returns smallint
language sql
immutable
parallel safe
as $$
  select case
    when public.app_unit_key(p_unit) = any (array[
      'τεμ', 'τμχ', 'τεμαχιο', 'τεμαχια', 'piece', 'pieces', 'pc', 'pcs',
      'ζευγος', 'ζευγη', 'pair', 'pairs',
      'σετ', 'set', 'sets', 'kit', 'kits',
      'συσκευασια', 'συσκευασιες', 'πακετο', 'πακετα', 'package', 'packages',
      'ρολο', 'ρολα', 'roll', 'rolls',
      'σακι', 'σακια', 'σακος', 'σακοι', 'bag', 'bags',
      'φιαλη', 'φιαλες', 'bottle', 'bottles',
      'δοχειο', 'δοχεια', 'can', 'cans',
      'υπηρεσια', 'υπηρεσιες', 'εργασια', 'εργασιες',
      'κατ''αποκοπη', 'αποκοπη', 'lumpsum', 'αρ', 'no'
    ]) then 0
    else 3
  end::smallint
$$;

create or replace function public.app_quantity_matches_scale(
  p_quantity numeric,
  p_scale smallint
)
returns boolean
language sql
immutable
parallel safe
as $$
  select p_quantity is not null
    and p_scale between 0 and 3
    and p_quantity = round(p_quantity, p_scale)
$$;

alter table public.materials
  add column if not exists quantity_scale smallint;

update public.materials m
set quantity_scale = public.app_unit_default_scale(m.unit)
where m.quantity_scale is null;

alter table public.materials
  alter column quantity_scale set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.materials'::regclass
      and conname = 'materials_quantity_scale_check'
  ) then
    alter table public.materials
      add constraint materials_quantity_scale_check
      check (quantity_scale between 0 and 3) not valid;
    alter table public.materials validate constraint materials_quantity_scale_check;
  end if;
end;
$$;

alter table public.mo_contract_items
  add column if not exists quantity_scale smallint null;

alter table public.mo_order_items
  add column if not exists quantity_scale smallint null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.mo_contract_items'::regclass
      and conname = 'mo_contract_items_quantity_scale_check'
  ) then
    alter table public.mo_contract_items
      add constraint mo_contract_items_quantity_scale_check
      check (quantity_scale is null or quantity_scale between 0 and 3) not valid;
    alter table public.mo_contract_items validate constraint mo_contract_items_quantity_scale_check;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.mo_order_items'::regclass
      and conname = 'mo_order_items_quantity_scale_check'
  ) then
    alter table public.mo_order_items
      add constraint mo_order_items_quantity_scale_check
      check (quantity_scale is null or quantity_scale between 0 and 3) not valid;
    alter table public.mo_order_items validate constraint mo_order_items_quantity_scale_check;
  end if;
end;
$$;

create or replace function public.app_material_quantity_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.unit := nullif(btrim(coalesce(new.unit, '')), '');

  if new.quantity_scale is null then
    new.quantity_scale := public.app_unit_default_scale(new.unit);
  elsif tg_op = 'UPDATE'
    and new.unit is distinct from old.unit
    and new.quantity_scale is not distinct from old.quantity_scale then
    new.quantity_scale := public.app_unit_default_scale(new.unit);
  end if;

  if new.quantity_scale not between 0 and 3 then
    raise exception 'Η ακρίβεια ποσότητας πρέπει να είναι από 0 έως 3 δεκαδικά ψηφία.';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_material_quantity_guard on public.materials;
create trigger trg_material_quantity_guard
  before insert or update of unit, quantity_scale on public.materials
  for each row execute function public.app_material_quantity_guard();

create or replace function public.app_request_line_quantity_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_scale smallint;
  v_unit text;
begin
  select m.quantity_scale, m.unit
  into v_scale, v_unit
  from public.materials m
  where m.id = new.material_id;

  if not found then
    raise exception 'Δεν βρέθηκε το είδος της γραμμής ποσότητας.';
  end if;

  if coalesce(new.comments, '') = '__hidden__' and new.quantity = 0 then
    return new;
  end if;
  if new.quantity is null or new.quantity <= 0 then
    raise exception 'Η ποσότητα πρέπει να είναι μεγαλύτερη από μηδέν.';
  end if;
  if not public.app_quantity_matches_scale(new.quantity, v_scale) then
    if v_scale = 0 then
      raise exception 'Η μονάδα «%» επιτρέπει μόνο ακέραιες ποσότητες.', coalesce(v_unit, 'τεμ.');
    end if;
    raise exception 'Η μονάδα «%» επιτρέπει έως % δεκαδικά ψηφία.', coalesce(v_unit, '—'), v_scale;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_request_line_quantity_guard on public.request_lines;
create trigger trg_request_line_quantity_guard
  before insert or update of material_id, quantity, comments on public.request_lines
  for each row execute function public.app_request_line_quantity_guard();

create or replace function public.app_locked_study_quantity_snapshot()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_line jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_scale smallint;
  v_unit text;
  v_quantity numeric;
begin
  if new.lines is null or jsonb_typeof(new.lines::jsonb) <> 'array' then
    raise exception 'Το στιγμιότυπο γραμμών της μελέτης δεν είναι έγκυρο.';
  end if;

  for v_line in select value from jsonb_array_elements(new.lines::jsonb)
  loop
    select m.quantity_scale, m.unit
    into v_scale, v_unit
    from public.materials m
    where m.id::text = v_line ->> 'material_id';

    v_unit := coalesce(nullif(v_line ->> 'unit', ''), v_unit, '');
    v_scale := coalesce(v_scale, public.app_unit_default_scale(v_unit));
    v_quantity := nullif(v_line ->> 'quantity', '')::numeric;
    if v_quantity is null or v_quantity <= 0
       or not public.app_quantity_matches_scale(v_quantity, v_scale) then
      raise exception 'Μη έγκυρη ποσότητα % για τη μονάδα «%».', v_quantity, coalesce(v_unit, '—');
    end if;

    v_lines := v_lines || jsonb_build_array(
      v_line || jsonb_build_object('quantity_scale', v_scale)
    );
  end loop;

  new.lines := v_lines;
  return new;
end;
$$;

drop trigger if exists trg_locked_study_quantity_snapshot on public.locked_studies;
create trigger trg_locked_study_quantity_snapshot
  before insert on public.locked_studies
  for each row execute function public.app_locked_study_quantity_snapshot();

create or replace function public.app_contract_item_quantity_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_snapshot_scale smallint;
  v_material_scale smallint;
begin
  if new.quantity_scale is null then
    select nullif(x.value ->> 'quantity_scale', '')::smallint
    into v_snapshot_scale
    from public.mo_contracts c
    join public.locked_studies s on s.id = c.source_study_id
    cross join lateral jsonb_array_elements(coalesce(s.lines::jsonb, '[]'::jsonb)) x(value)
    where c.id = new.contract_id
      and (
        (new.material_id is not null and x.value ->> 'material_id' = new.material_id::text)
        or (new.material_id is null and x.value ->> 'code' = new.code)
      )
    limit 1;

    if new.material_id is not null then
      select m.quantity_scale into v_material_scale
      from public.materials m where m.id = new.material_id;
    end if;

    new.quantity_scale := coalesce(
      v_snapshot_scale,
      v_material_scale,
      public.app_unit_default_scale(new.unit)
    );
  end if;

  if new.contract_qty is not null and (
    new.contract_qty <= 0
    or not public.app_quantity_matches_scale(new.contract_qty, new.quantity_scale)
  ) then
    raise exception 'Μη έγκυρη συμβατική ποσότητα % για τη μονάδα «%».', new.contract_qty, coalesce(new.unit, '—');
  end if;
  return new;
end;
$$;

drop trigger if exists trg_mo_contract_item_quantity_guard on public.mo_contract_items;
create trigger trg_mo_contract_item_quantity_guard
  before insert or update of contract_qty, unit, quantity_scale on public.mo_contract_items
  for each row execute function public.app_contract_item_quantity_guard();

create or replace function public.app_order_item_quantity_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  -- Τα αναγνωριστικά των συμβάσεων είναι UUID στο πλήρες schema v2.
  -- Η χρήση %type κρατά τη migration συμβατή με τον πραγματικό τύπο της βάσης.
  v_contract_id public.mo_contracts.id%type;
  v_item_contract_id public.mo_contract_items.contract_id%type;
  v_scale smallint;
  v_map jsonb;
  v_map_item jsonb;
  v_map_scale smallint;
  v_map_qty numeric;
begin
  select o.contract_id into v_contract_id
  from public.mo_orders o where o.id = new.order_id;
  if v_contract_id is null then
    raise exception 'Η γραμμή δελτίου δεν συνδέεται με ενεργή σύμβαση.';
  end if;

  if new.contract_item_id is not null then
    select i.contract_id,
           coalesce(i.quantity_scale, m.quantity_scale, public.app_unit_default_scale(i.unit))
    into v_item_contract_id, v_scale
    from public.mo_contract_items i
    left join public.materials m on m.id = i.material_id
    where i.id = new.contract_item_id;
    if v_item_contract_id is null or v_item_contract_id <> v_contract_id then
      raise exception 'Η γραμμή δελτίου αναφέρεται σε ξένο συμβατικό είδος.';
    end if;
  else
    v_scale := public.app_unit_default_scale(new.unit);
  end if;

  new.quantity_scale := coalesce(v_scale, new.quantity_scale, public.app_unit_default_scale(new.unit));
  if new.quantity is null or new.quantity <= 0
     or not public.app_quantity_matches_scale(new.quantity, new.quantity_scale) then
    raise exception 'Μη έγκυρη ποσότητα % για τη μονάδα «%».', new.quantity, coalesce(new.unit, '—');
  end if;

  v_map := coalesce(new.mapping::jsonb, '[]'::jsonb);
  if jsonb_typeof(v_map) = 'null' then v_map := '[]'::jsonb; end if;
  if jsonb_typeof(v_map) <> 'array' then
    raise exception 'Μη έγκυρη αντιστοίχιση συμβατικών ειδών.';
  end if;

  for v_map_item in select value from jsonb_array_elements(v_map)
  loop
    select coalesce(i.quantity_scale, m.quantity_scale, public.app_unit_default_scale(i.unit))
    into v_map_scale
    from public.mo_contract_items i
    left join public.materials m on m.id = i.material_id
    where i.id::text = v_map_item ->> 'contract_item_id'
      and i.contract_id = v_contract_id;
    if v_map_scale is null then
      raise exception 'Η αντιστοίχιση αναφέρεται σε ξένο συμβατικό είδος.';
    end if;
    v_map_qty := nullif(v_map_item ->> 'qty', '')::numeric;
    if v_map_qty is null or v_map_qty <= 0
       or not public.app_quantity_matches_scale(v_map_qty, v_map_scale) then
      raise exception 'Μη έγκυρη ισοδύναμη ποσότητα % στην αντιστοίχιση.', v_map_qty;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists trg_mo_order_item_quantity_guard on public.mo_order_items;
create trigger trg_mo_order_item_quantity_guard
  before insert or update of contract_item_id, mapping, unit, quantity, quantity_scale
  on public.mo_order_items
  for each row execute function public.app_order_item_quantity_guard();

create index if not exists idx_mo_orders_contract_status
  on public.mo_orders (contract_id, status);
create index if not exists idx_mo_order_items_contract_item
  on public.mo_order_items (contract_item_id);

create or replace function public.get_contract_balance_atomic(p_contract_id text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_contract_id public.mo_contracts.id%type;
  v_study_id public.locked_studies.id%type;
  v_unit_id bigint;
  v_study_total numeric(14,2);
  v_contract_total numeric(14,2);
  v_committed_net numeric(14,2);
  v_open_net numeric(14,2);
  v_received_net numeric(14,2);
  v_cancelled_net numeric(14,2);
  v_active_orders integer;
  v_open_orders integer;
  v_received_orders integer;
  v_items jsonb;
begin
  select c.id, c.source_study_id, c.municipal_unit_id,
         round(coalesce(s.net_total, c.total_amount, 0), 2),
         round(coalesce(c.total_amount, s.net_total, 0), 2)
  into v_contract_id, v_study_id, v_unit_id, v_study_total, v_contract_total
  from public.mo_contracts c
  left join public.locked_studies s on s.id = c.source_study_id
  where c.id::text = p_contract_id;

  if v_contract_id is null then
    raise exception 'Δεν βρέθηκε η σύμβαση.';
  end if;
  if not public.app_can_read_unit(v_unit_id) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα προβολής της συγκεκριμένης σύμβασης.';
  end if;

  select
    round(coalesce(sum(o.subtotal) filter (where o.status in ('issued','sent','received')), 0), 2),
    round(coalesce(sum(o.subtotal) filter (where o.status in ('issued','sent')), 0), 2),
    round(coalesce(sum(o.subtotal) filter (where o.status = 'received'), 0), 2),
    round(coalesce(sum(o.subtotal) filter (where o.status = 'cancelled'), 0), 2),
    count(*) filter (where o.status in ('issued','sent','received')),
    count(*) filter (where o.status in ('issued','sent')),
    count(*) filter (where o.status = 'received')
  into v_committed_net, v_open_net, v_received_net, v_cancelled_net,
       v_active_orders, v_open_orders, v_received_orders
  from public.mo_orders o
  where o.contract_id = v_contract_id;

  with usage_rows as (
    select oi.contract_item_id::text as contract_item_id,
           oi.quantity::numeric as quantity,
           o.status
    from public.mo_order_items oi
    join public.mo_orders o on o.id = oi.order_id
    where o.contract_id = v_contract_id
      and o.status in ('issued','sent','received')
      and oi.contract_item_id is not null
    union all
    select mp.value ->> 'contract_item_id' as contract_item_id,
           (mp.value ->> 'qty')::numeric as quantity,
           o.status
    from public.mo_order_items oi
    join public.mo_orders o on o.id = oi.order_id
    cross join lateral jsonb_array_elements(
      case when jsonb_typeof(coalesce(oi.mapping::jsonb, '[]'::jsonb)) = 'array'
        then coalesce(oi.mapping::jsonb, '[]'::jsonb) else '[]'::jsonb end
    ) mp(value)
    where o.contract_id = v_contract_id
      and o.status in ('issued','sent','received')
      and coalesce(mp.value ->> 'qty', '') ~ '^[+-]?[0-9]+([.][0-9]+)?$'
  ), usage_totals as (
    select contract_item_id,
           coalesce(sum(quantity), 0) as committed_qty,
           coalesce(sum(quantity) filter (where status in ('issued','sent')), 0) as open_qty,
           coalesce(sum(quantity) filter (where status = 'received'), 0) as received_qty
    from usage_rows
    group by contract_item_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'contract_item_id', ci.id::text,
      'code', ci.code,
      'description', ci.description,
      'unit', ci.unit,
      'quantity_scale', coalesce(ci.quantity_scale, m.quantity_scale, public.app_unit_default_scale(ci.unit)),
      'contract_qty', ci.contract_qty,
      'committed_qty', coalesce(u.committed_qty, 0),
      'open_qty', coalesce(u.open_qty, 0),
      'received_qty', coalesce(u.received_qty, 0),
      'remaining_qty', case when ci.contract_qty is null then null
        else ci.contract_qty - coalesce(u.committed_qty, 0) end,
      'unit_price', ci.unit_price,
      'committed_value', round(coalesce(u.committed_qty, 0) * coalesce(ci.unit_price, 0), 2),
      'received_value', round(coalesce(u.received_qty, 0) * coalesce(ci.unit_price, 0), 2)
    ) order by ci.id
  ), '[]'::jsonb)
  into v_items
  from public.mo_contract_items ci
  left join public.materials m on m.id = ci.material_id
  left join usage_totals u on u.contract_item_id = ci.id::text
  where ci.contract_id = v_contract_id;

  return jsonb_build_object(
    'contract_id', v_contract_id::text,
    'study_id', v_study_id::text,
    'study_total', v_study_total,
    'contract_total', v_contract_total,
    'committed_net', v_committed_net,
    'open_net', v_open_net,
    'received_net', v_received_net,
    'cancelled_net', v_cancelled_net,
    'remaining_net', round(v_contract_total - v_committed_net, 2),
    'active_order_count', v_active_orders,
    'open_order_count', v_open_orders,
    'received_order_count', v_received_orders,
    'items', v_items
  );
end;
$$;

revoke all on function public.get_contract_balance_atomic(text) from public, anon;
grant execute on function public.get_contract_balance_atomic(text) to authenticated;

create or replace function public.app_schema_version()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select '36.3'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

comment on column public.materials.quantity_scale is
  'Μέγιστος αριθμός δεκαδικών ψηφίων ποσότητας: 0 για διακριτές μονάδες, έως 3 για συνεχείς μονάδες.';
comment on function public.get_contract_balance_atomic(text) is
  'Ενιαία εικόνα οικονομικού και ποσοτικού υπολοίπου σύμβασης, με ενεργά, ανοικτά και παραληφθέντα δελτία.';

commit;
