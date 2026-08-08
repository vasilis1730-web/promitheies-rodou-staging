begin;

-- v36.2 / Βήμα 2B
-- Κάθε σύνθετη ενέργεια της εφαρμογής εκτελείται πλέον μέσα σε μία
-- συναλλαγή PostgreSQL, με εξουσιοδότηση και τελικούς ελέγχους στη βάση.

do $$
begin
  if exists (
    select 1
    from public.unit_requests
    group by municipal_unit_id, group_id, request_year
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Υπάρχουν διπλά unit_requests για την ίδια Δ.Ε./ομάδα/έτος. Απαιτείται ελεγχόμενη ενοποίηση πριν από τη v36.2.';
  end if;

  if exists (
    select 1
    from public.mo_contracts
    where source_study_id is not null
    group by source_study_id
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Υπάρχουν περισσότερες από μία αναθέσεις για την ίδια κλειδωμένη μελέτη.';
  end if;

  if exists (
    select 1
    from public.locked_studies
    group by municipal_unit_id, group_id, request_year, seq
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Υπάρχουν διπλοί αύξοντες αριθμοί κλειδωμένης μελέτης.';
  end if;

  if exists (
    select 1
    from public.mo_orders
    where order_no is not null
    group by order_no
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Υπάρχουν διπλοί αριθμοί δελτίων στο μητρώο.';
  end if;
end;
$$;

create unique index if not exists uq_unit_requests_context
  on public.unit_requests (municipal_unit_id, group_id, request_year);
create unique index if not exists uq_mo_contracts_source_study
  on public.mo_contracts (source_study_id);
create unique index if not exists uq_locked_studies_sequence
  on public.locked_studies (municipal_unit_id, group_id, request_year, seq);
create unique index if not exists uq_mo_orders_order_no
  on public.mo_orders (order_no) where order_no is not null;

create table if not exists public.mo_order_number_counters (
  scope text primary key,
  last_value bigint not null default 0 check (last_value >= 0),
  updated_at timestamptz not null default now()
);

alter table public.mo_order_number_counters enable row level security;
revoke all on table public.mo_order_number_counters from anon, authenticated;

-- Συνέχιση της αρίθμησης από τα ήδη αποθηκευμένα δελτία της v36. Η εισαγωγή
-- αφορά μόνο αριθμούς που ακολουθούν το υφιστάμενο πρότυπο ΔΥ/ΔΕ-έτος-Δ.Ε.-α/α.
-- Άλλες, ιστορικές μορφές παραμένουν ανέπαφες και προστατεύονται από το
-- μοναδικό index του order_no.
insert into public.mo_order_number_counters (scope, last_value, updated_at)
select
  'mo-' || parts[2] || '-u' || (parts[3]::integer)::text || '-'
    || case when parts[1] = 'ΔΕ' then 'service' else 'procurement' end,
  max(parts[4]::bigint),
  now()
from public.mo_orders o
cross join lateral regexp_match(
  btrim(o.order_no),
  '^(ΔΥ|ΔΕ)-([0-9]{4})-([0-9]+)-([0-9]+)$'
) parts
where o.order_no is not null
group by parts[1], parts[2], parts[3]
on conflict (scope) do update
set last_value = greatest(
      public.mo_order_number_counters.last_value,
      excluded.last_value
    ),
    updated_at = now();

create or replace function public.app_next_order_sequence(p_scope text)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_value bigint;
begin
  if nullif(btrim(coalesce(p_scope, '')), '') is null then
    raise exception 'Απαιτείται πεδίο αρίθμησης δελτίου.';
  end if;

  insert into public.mo_order_number_counters (scope, last_value, updated_at)
  values (btrim(p_scope), 1, now())
  on conflict (scope) do update
    set last_value = public.mo_order_number_counters.last_value + 1,
        updated_at = now()
  returning last_value into v_value;
  return v_value;
end;
$$;

revoke all on function public.app_next_order_sequence(text) from public, anon, authenticated;

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
    raise exception 'Το αίτημα περιέχει άγνωστο, διπλό ή ξένο προς την ομάδα είδος.';
  end if;
end;
$$;

revoke all on function public.app_validate_request_lines(bigint,jsonb)
  from public, anon, authenticated;

create or replace function public.save_unit_request_atomic(
  p_request_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_title text,
  p_action text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_request_id public.unit_requests.id%type;
  -- Keep the local value on the exact enum type used by unit_requests.status.
  -- A plain text variable cannot be assigned to request_status implicitly.
  v_status public.unit_requests.status%type;
  v_now timestamptz := now();
  v_net numeric(14,2);
  v_items integer;
  v_hidden integer;
begin
  if not public.app_can_write_unit(p_municipal_unit_id) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα εγγραφής στη συγκεκριμένη Δημοτική Ενότητα.';
  end if;
  if p_request_year < 2023 or p_request_year > 2100 then
    raise exception 'Μη έγκυρο οικονομικό έτος.';
  end if;
  if p_action not in ('save', 'save_clean') then
    raise exception 'Μη επιτρεπτή ενέργεια αποθήκευσης.';
  end if;
  if not exists (select 1 from public.municipal_units u where u.id::bigint = p_municipal_unit_id) then
    raise exception 'Άγνωστη Δημοτική Ενότητα.';
  end if;
  if not exists (select 1 from public.procurement_groups g where g.id::bigint = p_group_id) then
    raise exception 'Άγνωστη ομάδα υλικών/υπηρεσιών.';
  end if;

  perform public.app_validate_request_lines(p_group_id, p_lines);

  if nullif(p_request_id, '') is not null then
    select r.id into v_request_id
    from public.unit_requests r
    where r.id::text = p_request_id
      and r.municipal_unit_id::bigint = p_municipal_unit_id
      and r.group_id::bigint = p_group_id
      and r.request_year = p_request_year
    for update;
    if v_request_id is null then
      raise exception 'Το αίτημα δεν αντιστοιχεί στη συγκεκριμένη Δ.Ε./ομάδα/έτος.';
    end if;
  else
    select r.id into v_request_id
    from public.unit_requests r
    where r.municipal_unit_id::bigint = p_municipal_unit_id
      and r.group_id::bigint = p_group_id
      and r.request_year = p_request_year
    for update;
  end if;

  if v_request_id is null then
    insert into public.unit_requests (
      municipal_unit_id, group_id, request_year, title, status,
      created_by, updated_by, updated_at
    ) values (
      p_municipal_unit_id, p_group_id, p_request_year,
      coalesce(nullif(btrim(p_title), ''), 'Δελτίο προμήθειας ' || p_request_year),
      'draft', auth.uid(), auth.uid(), v_now
    ) returning id into v_request_id;
  end if;

  delete from public.request_lines l where l.request_id = v_request_id;

  insert into public.request_lines (
    request_id, material_id, quantity, unit_price, comments, updated_by
  )
  select
    v_request_id,
    m.id,
    (x.value ->> 'quantity')::numeric,
    (x.value ->> 'unit_price')::numeric,
    nullif(x.value ->> 'comments', ''),
    auth.uid()
  from jsonb_array_elements(p_lines) x(value)
  join lateral (
    select mm.id
    from public.materials mm
    where mm.group_id::bigint = p_group_id
      and (
        (nullif(x.value ->> 'material_id', '') is not null and mm.id::text = x.value ->> 'material_id')
        or (
          nullif(x.value ->> 'material_id', '') is null
          and mm.code = x.value ->> 'material_code'
        )
      )
    limit 1
  ) m on true;

  v_status := case when p_action = 'save_clean' then 'cleaned' else 'saved' end;
  update public.unit_requests r
  set status = v_status,
      title = coalesce(nullif(btrim(p_title), ''), r.title),
      updated_by = auth.uid(),
      updated_at = v_now,
      saved_at = case when p_action = 'save' then v_now else r.saved_at end,
      cleaned_at = case when p_action = 'save_clean' then v_now else r.cleaned_at end
  where r.id = v_request_id;

  select
    round(coalesce(sum(
      case when coalesce(x.value ->> 'comments', '') = '__hidden__' then 0
      else (x.value ->> 'quantity')::numeric * (x.value ->> 'unit_price')::numeric end
    ), 0), 2),
    count(*) filter (
      where coalesce(x.value ->> 'comments', '') <> '__hidden__'
        and (x.value ->> 'quantity')::numeric > 0
    ),
    count(*) filter (where coalesce(x.value ->> 'comments', '') = '__hidden__')
  into v_net, v_items, v_hidden
  from jsonb_array_elements(p_lines) x(value);

  insert into public.saved_versions (request_id, action, created_by, snapshot)
  values (
    v_request_id, p_action, auth.uid(),
    jsonb_build_object(
      'items', v_items, 'hidden', v_hidden, 'net', v_net,
      'lines', p_lines, 'saved_at', v_now
    )
  );

  perform public.app_write_audit(
    p_action, 'unit_requests', v_request_id::text, p_municipal_unit_id, null,
    null,
    jsonb_build_object('status', v_status, 'items', v_items, 'hidden', v_hidden, 'net', v_net),
    jsonb_build_object('group_id', p_group_id, 'request_year', p_request_year)
  );

  return jsonb_build_object(
    'request_id', v_request_id::text,
    'status', v_status,
    'items', v_items,
    'hidden', v_hidden,
    'net', v_net
  );
end;
$$;

revoke all on function public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)
  from public, anon;
grant execute on function public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)
  to authenticated;

create or replace function public.copy_unit_request_atomic(
  p_source_municipal_unit_id bigint,
  p_destination_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_title text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_request_id public.unit_requests.id%type;
  v_now timestamptz := now();
  v_net numeric(14,2);
  v_items integer;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Η αντιγραφή μεταξύ Δημοτικών Ενοτήτων επιτρέπεται μόνο σε διαχειριστή.';
  end if;
  if p_source_municipal_unit_id = p_destination_municipal_unit_id then
    raise exception 'Η πηγή και ο προορισμός πρέπει να είναι διαφορετικές Δημοτικές Ενότητες.';
  end if;
  if not exists (
    select 1 from public.municipal_units u
    where u.id::bigint = p_destination_municipal_unit_id
  ) then
    raise exception 'Άγνωστη Δημοτική Ενότητα προορισμού.';
  end if;

  perform public.app_validate_request_lines(p_group_id, p_lines);

  select r.id into v_request_id
  from public.unit_requests r
  where r.municipal_unit_id::bigint = p_destination_municipal_unit_id
    and r.group_id::bigint = p_group_id
    and r.request_year = p_request_year
  for update;

  if v_request_id is null then
    insert into public.unit_requests (
      municipal_unit_id, group_id, request_year, title, status,
      saved_at, created_by, updated_by, updated_at
    ) values (
      p_destination_municipal_unit_id, p_group_id, p_request_year,
      coalesce(nullif(btrim(p_title), ''), 'Δελτίο προμήθειας ' || p_request_year),
      'saved', v_now, auth.uid(), auth.uid(), v_now
    ) returning id into v_request_id;
  end if;

  delete from public.request_lines l where l.request_id = v_request_id;
  insert into public.request_lines (
    request_id, material_id, quantity, unit_price, comments, updated_by
  )
  select
    v_request_id, m.id,
    (x.value ->> 'quantity')::numeric,
    (x.value ->> 'unit_price')::numeric,
    nullif(x.value ->> 'comments', ''), auth.uid()
  from jsonb_array_elements(p_lines) x(value)
  join lateral (
    select mm.id from public.materials mm
    where mm.group_id::bigint = p_group_id
      and mm.id::text = x.value ->> 'material_id'
    limit 1
  ) m on true;

  update public.unit_requests r
  set status = 'saved', saved_at = v_now, updated_at = v_now, updated_by = auth.uid()
  where r.id = v_request_id;

  select
    round(coalesce(sum(
      case when coalesce(x.value ->> 'comments', '') = '__hidden__' then 0
      else (x.value ->> 'quantity')::numeric * (x.value ->> 'unit_price')::numeric end
    ), 0), 2),
    count(*) filter (
      where coalesce(x.value ->> 'comments', '') <> '__hidden__'
        and (x.value ->> 'quantity')::numeric > 0
    )
  into v_net, v_items
  from jsonb_array_elements(p_lines) x(value);

  insert into public.saved_versions (request_id, action, created_by, snapshot)
  values (
    v_request_id, 'copy', auth.uid(),
    jsonb_build_object(
      'source_unit_id', p_source_municipal_unit_id,
      'destination_unit_id', p_destination_municipal_unit_id,
      'group_id', p_group_id, 'items', v_items, 'net', v_net,
      'lines', p_lines, 'saved_at', v_now
    )
  );

  perform public.app_write_audit(
    'request_copied', 'unit_requests', v_request_id::text,
    p_destination_municipal_unit_id, null, null,
    jsonb_build_object('items', v_items, 'net', v_net),
    jsonb_build_object(
      'source_unit_id', p_source_municipal_unit_id,
      'group_id', p_group_id, 'request_year', p_request_year
    )
  );

  return jsonb_build_object('request_id', v_request_id::text, 'items', v_items, 'net', v_net);
end;
$$;

revoke all on function public.copy_unit_request_atomic(bigint,bigint,bigint,integer,text,jsonb)
  from public, anon;
grant execute on function public.copy_unit_request_atomic(bigint,bigint,bigint,integer,text,jsonb)
  to authenticated;

create or replace function public.import_catalog_request_atomic(
  p_request_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_title text,
  p_material_updates jsonb,
  p_new_materials jsonb,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_request_id public.unit_requests.id%type;
  v_material_id public.materials.id%type;
  v_item jsonb;
  v_patch jsonb;
  v_now timestamptz := now();
  v_updates integer := 0;
  v_inserts integer := 0;
  v_items integer := 0;
  v_net numeric(14,2) := 0;
begin
  if not public.app_can_write_unit(p_municipal_unit_id) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα εισαγωγής στη συγκεκριμένη Δημοτική Ενότητα.';
  end if;
  if p_material_updates is null or jsonb_typeof(p_material_updates) <> 'array'
     or p_new_materials is null or jsonb_typeof(p_new_materials) <> 'array' then
    raise exception 'Οι αλλαγές καταλόγου πρέπει να είναι πίνακες JSON.';
  end if;
  if jsonb_array_length(p_material_updates) + jsonb_array_length(p_new_materials) > 5000 then
    raise exception 'Η εισαγωγή υπερβαίνει το όριο των 5.000 μεταβολών καταλόγου.';
  end if;
  if (jsonb_array_length(p_material_updates) > 0 or jsonb_array_length(p_new_materials) > 0)
     and not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο διαχειριστής μπορεί να μεταβάλει τον κεντρικό κατάλογο.';
  end if;

  for v_item in select value from jsonb_array_elements(p_material_updates)
  loop
    v_patch := coalesce(v_item -> 'patch', '{}'::jsonb);
    if jsonb_typeof(v_patch) <> 'object' then
      raise exception 'Μη έγκυρο πακέτο ενημέρωσης καταλόγου.';
    end if;

    select m.id into v_material_id
    from public.materials m
    where m.id::text = v_item ->> 'id'
      and m.group_id::bigint = p_group_id
    for update;
    if v_material_id is null then
      raise exception 'Δεν βρέθηκε είδος καταλόγου με id % στην επιλεγμένη ομάδα.', v_item ->> 'id';
    end if;

    update public.materials m
    set name = case when v_patch ? 'name' then nullif(btrim(v_patch ->> 'name'), '') else m.name end,
        short_name = case when v_patch ? 'short_name' then nullif(btrim(v_patch ->> 'short_name'), '') else m.short_name end,
        unit = case when v_patch ? 'unit' then nullif(btrim(v_patch ->> 'unit'), '') else m.unit end,
        cpv = case when v_patch ? 'cpv' then nullif(btrim(v_patch ->> 'cpv'), '') else m.cpv end,
        default_unit_price = case
          when v_patch ? 'default_unit_price' and jsonb_typeof(v_patch -> 'default_unit_price') = 'null' then null
          when v_patch ? 'default_unit_price' then (v_patch ->> 'default_unit_price')::numeric
          else m.default_unit_price
        end,
        technical_specs = case when v_patch ? 'technical_specs' then nullif(v_patch ->> 'technical_specs', '') else m.technical_specs end,
        subcategory = case when v_patch ? 'subcategory' then nullif(v_patch ->> 'subcategory', '') else m.subcategory end,
        standards = case when v_patch ? 'standards' then nullif(v_patch ->> 'standards', '') else m.standards end,
        ce_required = case when v_patch ? 'ce_required' then (v_patch ->> 'ce_required')::boolean else m.ce_required end,
        notes_for_tender = case when v_patch ? 'notes_for_tender' then nullif(v_patch ->> 'notes_for_tender', '') else m.notes_for_tender end,
        updated_at = v_now
    where m.id = v_material_id;
    v_updates := v_updates + 1;
  end loop;

  for v_item in select value from jsonb_array_elements(p_new_materials)
  loop
    if nullif(btrim(coalesce(v_item ->> 'code', '')), '') is null
       or nullif(btrim(coalesce(v_item ->> 'name', '')), '') is null
       or nullif(btrim(coalesce(v_item ->> 'unit', '')), '') is null then
      raise exception 'Κάθε νέο είδος απαιτεί μοναδικό κωδικό, περιγραφή και μονάδα.';
    end if;
    if exists (
      select 1 from public.materials m
      where m.group_id::bigint = p_group_id and m.code = btrim(v_item ->> 'code')
    ) then
      raise exception 'Ο κωδικός νέου είδους % υπάρχει ήδη.', v_item ->> 'code';
    end if;

    insert into public.materials (
      group_id, code, name, short_name, unit, cpv, default_unit_price,
      technical_specs, subcategory, standards, ce_required,
      notes_for_tender, is_active, sort_order
    ) values (
      p_group_id,
      btrim(v_item ->> 'code'),
      btrim(v_item ->> 'name'),
      coalesce(nullif(btrim(v_item ->> 'short_name'), ''), btrim(v_item ->> 'name')),
      btrim(v_item ->> 'unit'),
      nullif(btrim(v_item ->> 'cpv'), ''),
      case when v_item ? 'default_unit_price' and jsonb_typeof(v_item -> 'default_unit_price') <> 'null'
        then (v_item ->> 'default_unit_price')::numeric else null end,
      nullif(v_item ->> 'technical_specs', ''),
      nullif(v_item ->> 'subcategory', ''),
      nullif(v_item ->> 'standards', ''),
      coalesce((v_item ->> 'ce_required')::boolean, false),
      nullif(v_item ->> 'notes_for_tender', ''),
      true,
      coalesce((v_item ->> 'sort_order')::integer, 0)
    ) returning id into v_material_id;
    v_inserts := v_inserts + 1;
  end loop;

  -- Η επικύρωση γίνεται μετά τις εγγραφές καταλόγου, αλλά παραμένει στην ίδια
  -- συναλλαγή. Οποιοδήποτε σφάλμα αναιρεί και τις προηγούμενες ενημερώσεις.
  perform public.app_validate_request_lines(p_group_id, p_lines);

  if nullif(p_request_id, '') is not null then
    select r.id into v_request_id
    from public.unit_requests r
    where r.id::text = p_request_id
      and r.municipal_unit_id::bigint = p_municipal_unit_id
      and r.group_id::bigint = p_group_id
      and r.request_year = p_request_year
    for update;
    if v_request_id is null then
      raise exception 'Το αίτημα εισαγωγής δεν αντιστοιχεί στην τρέχουσα Δ.Ε./ομάδα/έτος.';
    end if;
  else
    select r.id into v_request_id
    from public.unit_requests r
    where r.municipal_unit_id::bigint = p_municipal_unit_id
      and r.group_id::bigint = p_group_id
      and r.request_year = p_request_year
    for update;
  end if;

  if v_request_id is null then
    insert into public.unit_requests (
      municipal_unit_id, group_id, request_year, title, status,
      created_by, updated_by, updated_at
    ) values (
      p_municipal_unit_id, p_group_id, p_request_year,
      coalesce(nullif(btrim(p_title), ''), 'Δελτίο προμήθειας ' || p_request_year),
      'draft', auth.uid(), auth.uid(), v_now
    ) returning id into v_request_id;
  end if;

  delete from public.request_lines l where l.request_id = v_request_id;
  insert into public.request_lines (
    request_id, material_id, quantity, unit_price, comments, updated_by
  )
  select
    v_request_id, m.id,
    (x.value ->> 'quantity')::numeric,
    (x.value ->> 'unit_price')::numeric,
    nullif(x.value ->> 'comments', ''), auth.uid()
  from jsonb_array_elements(p_lines) x(value)
  join lateral (
    select mm.id
    from public.materials mm
    where mm.group_id::bigint = p_group_id
      and (
        (nullif(x.value ->> 'material_id', '') is not null and mm.id::text = x.value ->> 'material_id')
        or (
          nullif(x.value ->> 'material_id', '') is null
          and mm.code = x.value ->> 'material_code'
        )
      )
    limit 1
  ) m on true;

  update public.unit_requests r
  set status = 'saved', saved_at = v_now, updated_at = v_now, updated_by = auth.uid()
  where r.id = v_request_id;

  select
    count(*) filter (
      where coalesce(x.value ->> 'comments', '') <> '__hidden__'
        and (x.value ->> 'quantity')::numeric > 0
    ),
    round(coalesce(sum(
      case when coalesce(x.value ->> 'comments', '') = '__hidden__' then 0
      else (x.value ->> 'quantity')::numeric * (x.value ->> 'unit_price')::numeric end
    ), 0), 2)
  into v_items, v_net
  from jsonb_array_elements(p_lines) x(value);

  insert into public.saved_versions (request_id, action, created_by, snapshot)
  values (
    v_request_id, 'import', auth.uid(),
    jsonb_build_object(
      'items', v_items, 'net', v_net, 'catalog_updates', v_updates,
      'catalog_inserts', v_inserts, 'lines', p_lines, 'saved_at', v_now
    )
  );

  perform public.app_write_audit(
    'excel_import', 'unit_requests', v_request_id::text, p_municipal_unit_id, null,
    null,
    jsonb_build_object(
      'items', v_items, 'net', v_net,
      'catalog_updates', v_updates, 'catalog_inserts', v_inserts
    ),
    jsonb_build_object('group_id', p_group_id, 'request_year', p_request_year)
  );

  return jsonb_build_object(
    'request_id', v_request_id::text, 'items', v_items, 'net', v_net,
    'catalog_updates', v_updates, 'catalog_inserts', v_inserts
  );
end;
$$;

revoke all on function public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  from public, anon;
grant execute on function public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  to authenticated;

create or replace function public.lock_study_atomic(
  p_request_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_label text,
  p_supplier_name text,
  p_kimdis_url text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_request_id public.unit_requests.id%type;
  v_study_id public.locked_studies.id%type;
  v_configuration_id bigint;
  v_award_group_id bigint;
  v_cap numeric(14,2);
  v_committed numeric(14,2);
  v_net numeric(14,2);
  v_item_count integer;
  v_seq integer;
  v_snapshot jsonb;
  v_now timestamptz := now();
begin
  if not public.app_can_supervise() then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα κλειδώματος μελέτης.';
  end if;
  if p_municipal_unit_id = 11 then
    raise exception 'Το κλείδωμα γίνεται ανά Δημοτική Ενότητα και όχι στη συγκεντρωτική μονάδα.';
  end if;
  perform public.app_validate_request_lines(p_group_id, p_lines);

  select c.id, m.award_group_id, c.direct_award_cap
  into v_configuration_id, v_award_group_id, v_cap
  from public.award_group_configurations c
  join public.award_group_memberships m on m.configuration_id = c.id
  where c.budget_year = p_request_year
    and c.is_active
    and m.municipal_unit_id::bigint = p_municipal_unit_id
  for update of c;

  if v_configuration_id is null or v_award_group_id is null or v_cap is null then
    raise exception 'Δεν υπάρχει ενεργή απόφαση και πλήρης αντιστοίχιση ομάδας Δ.Ε. για το έτος %.', p_request_year;
  end if;

  select
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'material_id', m.id,
          'code', coalesce(m.code, ''),
          'name', coalesce(m.name, ''),
          'short_name', coalesce(m.short_name, ''),
          'unit', coalesce(m.unit, ''),
          'cpv', coalesce(m.cpv, ''),
          'quantity', (x.value ->> 'quantity')::numeric,
          'unit_price', (x.value ->> 'unit_price')::numeric,
          'subtotal', round(
            (x.value ->> 'quantity')::numeric * (x.value ->> 'unit_price')::numeric,
            2
          )
        ) order by coalesce(m.sort_order, 0), m.id
      ), '[]'::jsonb
    ),
    round(coalesce(sum(round(
      (x.value ->> 'quantity')::numeric * (x.value ->> 'unit_price')::numeric,
      2
    )), 0), 2),
    count(*)
  into v_snapshot, v_net, v_item_count
  from jsonb_array_elements(p_lines) x(value)
  join public.materials m
    on m.group_id::bigint = p_group_id
   and m.id::text = x.value ->> 'material_id'
  where coalesce(x.value ->> 'comments', '') <> '__hidden__'
    and (x.value ->> 'quantity')::numeric > 0;

  if v_item_count = 0 or v_net <= 0 then
    raise exception 'Δεν υπάρχουν γραμμές θετικής αξίας για κλείδωμα.';
  end if;

  select round(coalesce(sum(s.net_total), 0), 2)
  into v_committed
  from public.locked_studies s
  where s.award_group_id = v_award_group_id
    and s.group_id::bigint = p_group_id
    and s.request_year = p_request_year
    and s.record_status = 'active';

  if v_committed + v_net > v_cap then
    raise exception using
      errcode = '22003',
      message = format(
        'Το κλείδωμα αποκλείεται: το σύνολο %s € υπερβαίνει το όριο %s € χωρίς ΦΠΑ κατά %s €.',
        round(v_committed + v_net, 2), round(v_cap, 2), round(v_committed + v_net - v_cap, 2)
      );
  end if;

  if nullif(p_request_id, '') is not null then
    select r.id into v_request_id
    from public.unit_requests r
    where r.id::text = p_request_id
      and r.municipal_unit_id::bigint = p_municipal_unit_id
      and r.group_id::bigint = p_group_id
      and r.request_year = p_request_year
    for update;
    if v_request_id is null then
      raise exception 'Το αίτημα δεν αντιστοιχεί στη μελέτη που κλειδώνεται.';
    end if;
  else
    select r.id into v_request_id
    from public.unit_requests r
    where r.municipal_unit_id::bigint = p_municipal_unit_id
      and r.group_id::bigint = p_group_id
      and r.request_year = p_request_year
    for update;
  end if;

  if v_request_id is null then
    insert into public.unit_requests (
      municipal_unit_id, group_id, request_year, title, status,
      created_by, updated_by, updated_at
    ) values (
      p_municipal_unit_id, p_group_id, p_request_year,
      'Δελτίο προμήθειας ' || p_request_year, 'draft',
      auth.uid(), auth.uid(), v_now
    ) returning id into v_request_id;
  end if;

  select coalesce(max(s.seq), 0) + 1 into v_seq
  from public.locked_studies s
  where s.municipal_unit_id::bigint = p_municipal_unit_id
    and s.group_id::bigint = p_group_id
    and s.request_year = p_request_year;

  insert into public.locked_studies (
    municipal_unit_id, group_id, award_group_id, request_year,
    source_request_id, seq, label, net_total, item_count, lines,
    supplier_name, kimdis_url, locked_by, record_status
  ) values (
    p_municipal_unit_id, p_group_id, v_award_group_id, p_request_year,
    v_request_id, v_seq, nullif(btrim(coalesce(p_label, '')), ''),
    v_net, v_item_count, v_snapshot,
    nullif(btrim(coalesce(p_supplier_name, '')), ''),
    nullif(btrim(coalesce(p_kimdis_url, '')), ''),
    auth.uid(), 'active'
  ) returning id into v_study_id;

  delete from public.request_lines l where l.request_id = v_request_id;
  update public.unit_requests r
  set status = 'draft', updated_by = auth.uid(), updated_at = v_now
  where r.id = v_request_id;

  insert into public.saved_versions (request_id, action, created_by, snapshot)
  values (
    v_request_id, 'lock', auth.uid(),
    jsonb_build_object(
      'locked_study_id', v_study_id::text, 'seq', v_seq,
      'net', v_net, 'items', v_item_count, 'lines', v_snapshot,
      'award_group_id', v_award_group_id, 'locked_at', v_now
    )
  );

  perform public.app_write_audit(
    'study_locked', 'locked_studies', v_study_id::text,
    p_municipal_unit_id, null, null,
    jsonb_build_object(
      'seq', v_seq, 'net_total', v_net, 'item_count', v_item_count,
      'record_status', 'active'
    ),
    jsonb_build_object(
      'group_id', p_group_id, 'request_year', p_request_year,
      'award_group_id', v_award_group_id, 'committed_before', v_committed,
      'direct_award_cap', v_cap
    )
  );

  return jsonb_build_object(
    'study_id', v_study_id::text, 'request_id', v_request_id::text,
    'seq', v_seq, 'net', v_net, 'items', v_item_count,
    'award_group_id', v_award_group_id,
    'committed_after', v_committed + v_net,
    'direct_award_cap', v_cap
  );
end;
$$;

revoke all on function public.lock_study_atomic(text,bigint,bigint,integer,text,text,text,jsonb)
  from public, anon;
grant execute on function public.lock_study_atomic(text,bigint,bigint,integer,text,text,text,jsonb)
  to authenticated;

create or replace function public.amend_locked_study_atomic(
  p_study_id text,
  p_supplier_name text,
  p_kimdis_url text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_before public.locked_studies%rowtype;
  v_after public.locked_studies%rowtype;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο διαχειριστής μπορεί να διορθώσει μεταδεδομένα κλειδωμένης μελέτης.';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Η διορθωτική μεταβολή απαιτεί αιτιολογία.';
  end if;

  select * into v_before
  from public.locked_studies s
  where s.id::text = p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;
  if v_before.record_status <> 'active' then raise exception 'Ακυρωμένη μελέτη δεν μεταβάλλεται.'; end if;

  update public.locked_studies s
  set supplier_name = nullif(btrim(coalesce(p_supplier_name, '')), ''),
      kimdis_url = nullif(btrim(coalesce(p_kimdis_url, '')), '')
  where s.id = v_before.id
  returning * into v_after;

  perform public.app_write_audit(
    'study_metadata_amended', 'locked_studies', v_before.id::text,
    v_before.municipal_unit_id::bigint, p_reason,
    jsonb_build_object('supplier_name', v_before.supplier_name, 'kimdis_url', v_before.kimdis_url),
    jsonb_build_object('supplier_name', v_after.supplier_name, 'kimdis_url', v_after.kimdis_url),
    jsonb_build_object('seq', v_before.seq)
  );
  return jsonb_build_object('study_id', v_after.id::text, 'status', v_after.record_status);
end;
$$;

revoke all on function public.amend_locked_study_atomic(text,text,text,text) from public, anon;
grant execute on function public.amend_locked_study_atomic(text,text,text,text) to authenticated;

create or replace function public.cancel_locked_study_atomic(
  p_study_id text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_before public.locked_studies%rowtype;
  v_after public.locked_studies%rowtype;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο διαχειριστής μπορεί να ακυρώσει κλειδωμένη μελέτη.';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'Η ακύρωση απαιτεί υποχρεωτική αιτιολογία.';
  end if;

  select * into v_before
  from public.locked_studies s
  where s.id::text = p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;
  if v_before.record_status <> 'active' then raise exception 'Η μελέτη είναι ήδη ακυρωμένη.'; end if;

  if exists (
    select 1 from public.mo_orders o
    where o.study_id::text = p_study_id and o.status <> 'cancelled'
  ) then
    raise exception 'Η μελέτη έχει ενεργά ή πρόχειρα δελτία. Ακυρώστε/διαγράψτε πρώτα τα αντίστοιχα δελτία.';
  end if;

  update public.locked_studies s
  set record_status = 'cancelled',
      cancelled_at = now(),
      cancelled_by = auth.uid(),
      cancellation_reason = btrim(p_reason)
  where s.id = v_before.id
  returning * into v_after;

  if v_before.source_request_id is not null then
    insert into public.saved_versions (request_id, action, created_by, snapshot)
    values (
      v_before.source_request_id, 'cancel_lock', auth.uid(),
      jsonb_build_object(
        'locked_study_id', v_before.id::text, 'seq', v_before.seq,
        'net', v_before.net_total, 'reason', btrim(p_reason),
        'cancelled_at', v_after.cancelled_at
      )
    );
  end if;

  perform public.app_write_audit(
    'study_cancelled', 'locked_studies', v_before.id::text,
    v_before.municipal_unit_id::bigint, p_reason,
    jsonb_build_object('record_status', v_before.record_status, 'net_total', v_before.net_total),
    jsonb_build_object('record_status', v_after.record_status, 'net_total', v_after.net_total),
    jsonb_build_object('seq', v_before.seq, 'group_id', v_before.group_id, 'request_year', v_before.request_year)
  );

  return jsonb_build_object(
    'study_id', v_after.id::text, 'status', v_after.record_status,
    'cancelled_at', v_after.cancelled_at
  );
end;
$$;

revoke all on function public.cancel_locked_study_atomic(text,text) from public, anon;
grant execute on function public.cancel_locked_study_atomic(text,text) to authenticated;

create or replace function public.save_contract_atomic(
  p_contract_id text,
  p_study_id text,
  p_supplier_id text,
  p_title text,
  p_adam text,
  p_protocol_no text,
  p_start_date date,
  p_end_date date,
  p_vat_rate numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_study public.locked_studies%rowtype;
  v_contract public.mo_contracts%rowtype;
  v_before public.mo_contracts%rowtype;
  v_contract_id public.mo_contracts.id%type;
  v_supplier_id public.mo_suppliers.id%type;
  v_is_new boolean;
  v_items integer := 0;
begin
  select * into v_study
  from public.locked_studies s
  where s.id::text = p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;
  if v_study.record_status <> 'active' then raise exception 'Δεν καταχωρίζεται ανάθεση σε ακυρωμένη μελέτη.'; end if;
  if not public.app_can_write_unit(v_study.municipal_unit_id::bigint) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα καταχώρισης ανάθεσης για τη συγκεκριμένη Δ.Ε.';
  end if;

  select s.id into v_supplier_id
  from public.mo_suppliers s
  where s.id::text = p_supplier_id and coalesce(s.active, true)
  limit 1;
  if v_supplier_id is null then raise exception 'Δεν βρέθηκε ενεργός προμηθευτής/ανάδοχος.'; end if;
  if p_start_date is not null and p_end_date is not null and p_end_date < p_start_date then
    raise exception 'Η ημερομηνία λήξης δεν μπορεί να προηγείται της έναρξης.';
  end if;
  if p_vat_rate is null or p_vat_rate < 0 or p_vat_rate > 100 then
    raise exception 'Μη έγκυρος συντελεστής ΦΠΑ.';
  end if;

  v_is_new := nullif(p_contract_id, '') is null;
  if v_is_new then
    if exists (
      select 1 from public.mo_contracts c where c.source_study_id = v_study.id
    ) then
      raise exception 'Υπάρχει ήδη ανάθεση για τη συγκεκριμένη κλειδωμένη μελέτη.';
    end if;

    insert into public.mo_contracts (
      title, cpv, total_amount, vat_rate, active, municipal_unit_id,
      source_study_id, supplier_id, adam, protocol_no,
      start_date, end_date, updated_at, updated_by
    ) values (
      coalesce(nullif(btrim(p_title), ''), 'Ανάθεση κλειδωμένης μελέτης #' || v_study.seq),
      null, v_study.net_total, p_vat_rate, true, v_study.municipal_unit_id,
      v_study.id, v_supplier_id, nullif(btrim(coalesce(p_adam, '')), ''),
      nullif(btrim(coalesce(p_protocol_no, '')), ''),
      p_start_date, p_end_date, now(), auth.uid()
    ) returning * into v_contract;
    v_contract_id := v_contract.id;

    insert into public.mo_contract_items (
      contract_id, code, description, unit, cpv,
      contract_qty, unit_price, material_id
    )
    select
      v_contract_id,
      coalesce(nullif(x.value ->> 'code', ''), (row_number() over ())::text),
      coalesce(nullif(x.value ->> 'name', ''), nullif(x.value ->> 'short_name', ''), '—'),
      coalesce(x.value ->> 'unit', ''),
      nullif(x.value ->> 'cpv', ''),
      case when coalesce(x.value ->> 'quantity', '') ~ '^[+-]?[0-9]+([.][0-9]+)?$'
        then (x.value ->> 'quantity')::numeric else null end,
      case when coalesce(x.value ->> 'unit_price', '') ~ '^[+-]?[0-9]+([.][0-9]+)?$'
        then (x.value ->> 'unit_price')::numeric else 0 end,
      m.id
    from jsonb_array_elements(coalesce(v_study.lines::jsonb, '[]'::jsonb)) x(value)
    left join public.materials m on m.id::text = x.value ->> 'material_id';
    get diagnostics v_items = row_count;
  else
    select * into v_before
    from public.mo_contracts c
    where c.id::text = p_contract_id and c.source_study_id = v_study.id
    for update;
    if not found then raise exception 'Η ανάθεση δεν αντιστοιχεί στην επιλεγμένη μελέτη.'; end if;

    update public.mo_contracts c
    set supplier_id = v_supplier_id,
        adam = nullif(btrim(coalesce(p_adam, '')), ''),
        protocol_no = nullif(btrim(coalesce(p_protocol_no, '')), ''),
        start_date = p_start_date,
        end_date = p_end_date,
        updated_at = now(),
        updated_by = auth.uid()
    where c.id = v_before.id
    returning * into v_contract;
    v_contract_id := v_contract.id;
    select count(*) into v_items from public.mo_contract_items i where i.contract_id = v_contract_id;
  end if;

  perform public.app_write_audit(
    case when v_is_new then 'contract_created' else 'contract_amended' end,
    'mo_contracts', v_contract_id::text, v_study.municipal_unit_id::bigint,
    case when v_is_new then null else 'Διορθωτική ενημέρωση στοιχείων ανάθεσης' end,
    case when v_is_new then null else to_jsonb(v_before) end,
    to_jsonb(v_contract),
    jsonb_build_object('study_id', v_study.id::text, 'contract_items', v_items)
  );

  return jsonb_build_object(
    'contract_id', v_contract_id::text,
    'study_id', v_study.id::text,
    'items', v_items,
    'created', v_is_new
  );
end;
$$;

revoke all on function public.save_contract_atomic(text,text,text,text,text,text,date,date,numeric)
  from public, anon;
grant execute on function public.save_contract_atomic(text,text,text,text,text,text,date,date,numeric)
  to authenticated;

create or replace function public.save_order_atomic(
  p_order_id text,
  p_study_id text,
  p_order_date date,
  p_receiver_id text,
  p_usage_location text,
  p_notes text,
  p_vat_rate numeric,
  p_items jsonb,
  p_issue boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_study public.locked_studies%rowtype;
  v_contract public.mo_contracts%rowtype;
  v_order public.mo_orders%rowtype;
  v_before public.mo_orders%rowtype;
  v_ci public.mo_contract_items%rowtype;
  v_order_id public.mo_orders.id%type;
  v_receiver_id public.mo_receivers.id%type;
  v_item jsonb;
  v_map jsonb;
  v_map_item jsonb;
  v_normalized_map jsonb;
  v_normalized jsonb := '[]'::jsonb;
  v_usage jsonb := '{}'::jsonb;
  v_usage_entry record;
  v_qty numeric;
  v_price numeric;
  v_line_total numeric;
  v_covered numeric;
  v_subtotal numeric(14,2) := 0;
  v_vat numeric(14,2);
  v_total numeric(14,2);
  v_existing_net numeric(14,2);
  v_existing_qty numeric;
  v_requested_qty numeric;
  v_scope text;
  v_domain text;
  v_prefix text;
  v_order_no text;
  v_sequence bigint;
  v_year integer;
  v_is_new boolean;
begin
  select * into v_study
  from public.locked_studies s
  where s.id::text = p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;
  if v_study.record_status <> 'active' then raise exception 'Δεν δημιουργείται δελτίο για ακυρωμένη μελέτη.'; end if;
  if not public.app_can_write_unit(v_study.municipal_unit_id::bigint) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα έκδοσης δελτίου για τη συγκεκριμένη Δ.Ε.';
  end if;

  select * into v_contract
  from public.mo_contracts c
  where c.source_study_id = v_study.id and coalesce(c.active, true)
  for update;
  if not found then raise exception 'Δεν έχει καταχωριστεί ενεργή ανάθεση για τη μελέτη.'; end if;

  if p_order_date is null then raise exception 'Απαιτείται ημερομηνία δελτίου.'; end if;
  if nullif(btrim(coalesce(p_usage_location, '')), '') is null then
    raise exception 'Απαιτείται περιγραφή του τόπου/σκοπού χρήσης.';
  end if;
  if p_vat_rate is null or p_vat_rate < 0 or p_vat_rate > 100 then
    raise exception 'Μη έγκυρος συντελεστής ΦΠΑ.';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 500 then
    raise exception 'Το δελτίο πρέπει να περιλαμβάνει από 1 έως 500 γραμμές.';
  end if;

  if nullif(p_receiver_id, '') is not null then
    select r.id into v_receiver_id
    from public.mo_receivers r
    where r.id::text = p_receiver_id and coalesce(r.active, true)
    limit 1;
    if v_receiver_id is null then raise exception 'Δεν βρέθηκε ενεργός παραλαμβάνων.'; end if;
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(v_item ->> 'quantity', '') !~ '^[+-]?[0-9]+([.][0-9]+)?$'
       or coalesce(v_item ->> 'unit_price', '') !~ '^[+-]?[0-9]+([.][0-9]+)?$' then
      raise exception 'Κάθε γραμμή απαιτεί αριθμητική ποσότητα και τιμή.';
    end if;
    v_qty := (v_item ->> 'quantity')::numeric;
    v_price := (v_item ->> 'unit_price')::numeric;
    if v_qty <= 0 or v_price < 0 then
      raise exception 'Κάθε γραμμή απαιτεί ποσότητα μεγαλύτερη από μηδέν και μη αρνητική τιμή.';
    end if;

    if nullif(v_item ->> 'contract_item_id', '') is not null then
      select * into v_ci
      from public.mo_contract_items i
      where i.id::text = v_item ->> 'contract_item_id'
        and i.contract_id = v_contract.id;
      if not found then raise exception 'Γραμμή δελτίου αναφέρεται σε ξένο ή άγνωστο συμβατικό είδος.'; end if;

      v_price := v_ci.unit_price;
      v_line_total := round(v_qty * v_price, 2);
      v_normalized := v_normalized || jsonb_build_array(jsonb_build_object(
        'contract_item_id', v_ci.id::text,
        'is_custom', false,
        'description', v_ci.description,
        'unit', v_ci.unit,
        'quantity', v_qty,
        'unit_price', v_price,
        'line_total', v_line_total,
        'mapping', null
      ));
      if coalesce(p_issue, false) then
        v_usage := jsonb_set(
          v_usage, array[v_ci.id::text],
          to_jsonb(coalesce((v_usage ->> v_ci.id::text)::numeric, 0) + v_qty), true
        );
      end if;
    else
      if nullif(btrim(coalesce(v_item ->> 'description', '')), '') is null then
        raise exception 'Κάθε ελεύθερη γραμμή απαιτεί περιγραφή.';
      end if;
      v_line_total := round(v_qty * v_price, 2);
      v_map := coalesce(v_item -> 'mapping', '[]'::jsonb);
      if jsonb_typeof(v_map) = 'null' then v_map := '[]'::jsonb; end if;
      if jsonb_typeof(v_map) <> 'array' then raise exception 'Μη έγκυρη αντιστοίχιση ελεύθερης γραμμής.'; end if;
      v_normalized_map := '[]'::jsonb;
      v_covered := 0;

      for v_map_item in select value from jsonb_array_elements(v_map)
      loop
        if coalesce(v_map_item ->> 'qty', '') !~ '^[+-]?[0-9]+([.][0-9]+)?$'
           or (v_map_item ->> 'qty')::numeric <= 0 then
          raise exception 'Κάθε αντιστοίχιση απαιτεί θετική ισοδύναμη ποσότητα.';
        end if;
        select * into v_ci
        from public.mo_contract_items i
        where i.id::text = v_map_item ->> 'contract_item_id'
          and i.contract_id = v_contract.id;
        if not found then raise exception 'Αντιστοίχιση αναφέρεται σε ξένο ή άγνωστο συμβατικό είδος.'; end if;

        v_requested_qty := (v_map_item ->> 'qty')::numeric;
        v_covered := v_covered + v_requested_qty * v_ci.unit_price;
        v_normalized_map := v_normalized_map || jsonb_build_array(jsonb_build_object(
          'contract_item_id', v_ci.id::text, 'qty', v_requested_qty
        ));
        if coalesce(p_issue, false) then
          v_usage := jsonb_set(
            v_usage, array[v_ci.id::text],
            to_jsonb(coalesce((v_usage ->> v_ci.id::text)::numeric, 0) + v_requested_qty), true
          );
        end if;
      end loop;

      if coalesce(p_issue, false) and v_covered < v_line_total - 0.005 then
        raise exception 'Η ελεύθερη γραμμή «%» δεν έχει πλήρη συμβατική αντιστοίχιση.', v_item ->> 'description';
      end if;

      v_normalized := v_normalized || jsonb_build_array(jsonb_build_object(
        'contract_item_id', null,
        'is_custom', true,
        'description', btrim(v_item ->> 'description'),
        'unit', btrim(coalesce(v_item ->> 'unit', '')),
        'quantity', v_qty,
        'unit_price', v_price,
        'line_total', v_line_total,
        'mapping', case when jsonb_array_length(v_normalized_map) > 0 then v_normalized_map else null end
      ));
    end if;
    v_subtotal := v_subtotal + v_line_total;
  end loop;

  v_subtotal := round(v_subtotal, 2);
  v_vat := round(v_subtotal * p_vat_rate / 100, 2);
  v_total := v_subtotal + v_vat;
  v_is_new := nullif(p_order_id, '') is null;

  if not v_is_new then
    select * into v_before
    from public.mo_orders o
    where o.id::text = p_order_id and o.study_id = v_study.id
    for update;
    if not found then raise exception 'Το δελτίο δεν αντιστοιχεί στην επιλεγμένη μελέτη.'; end if;
    if v_before.status <> 'draft' then
      raise exception 'Εκδοθέν δελτίο είναι αμετάβλητο. Για διόρθωση απαιτείται ακύρωση και νέα έκδοση.';
    end if;
  end if;

  if coalesce(p_issue, false) then
    select round(coalesce(sum(o.subtotal), 0), 2)
    into v_existing_net
    from public.mo_orders o
    where o.study_id = v_study.id
      and o.status in ('issued', 'sent', 'received')
      and (p_order_id is null or o.id::text <> p_order_id);

    if v_existing_net + v_subtotal > v_study.net_total + 0.005 then
      raise exception using
        errcode = '22003',
        message = format(
          'Το δελτίο υπερβαίνει το διαθέσιμο υπόλοιπο της μελέτης: δεσμευμένα %s €, νέο %s €, μελέτη %s €.',
          round(v_existing_net, 2), round(v_subtotal, 2), round(v_study.net_total, 2)
        );
    end if;

    for v_usage_entry in select key, value from jsonb_each_text(v_usage)
    loop
      select * into v_ci
      from public.mo_contract_items i
      where i.id::text = v_usage_entry.key and i.contract_id = v_contract.id;
      if not found then raise exception 'Δεν βρέθηκε συμβατικό είδος κατά τον τελικό έλεγχο.'; end if;

      select coalesce(sum(q.qty), 0) into v_existing_qty
      from (
        select oi.quantity::numeric as qty
        from public.mo_order_items oi
        join public.mo_orders o on o.id = oi.order_id
        where o.study_id = v_study.id
          and o.status in ('issued', 'sent', 'received')
          and (p_order_id is null or o.id::text <> p_order_id)
          and oi.contract_item_id::text = v_usage_entry.key
        union all
        select (mp.value ->> 'qty')::numeric as qty
        from public.mo_order_items oi
        join public.mo_orders o on o.id = oi.order_id
        cross join lateral jsonb_array_elements(coalesce(oi.mapping::jsonb, '[]'::jsonb)) mp(value)
        where o.study_id = v_study.id
          and o.status in ('issued', 'sent', 'received')
          and (p_order_id is null or o.id::text <> p_order_id)
          and mp.value ->> 'contract_item_id' = v_usage_entry.key
      ) q;

      v_requested_qty := v_usage_entry.value::numeric;
      if v_ci.contract_qty is not null
         and v_existing_qty + v_requested_qty > v_ci.contract_qty + 0.000000001 then
        raise exception using
          errcode = '22003',
          message = format(
            'Υπέρβαση συμβατικής ποσότητας στο «%s»: συμβατική %s, ήδη αναληφθείσα %s, νέο δελτίο %s.',
            v_ci.description, v_ci.contract_qty, v_existing_qty, v_requested_qty
          );
      end if;
    end loop;
  end if;

  if v_is_new then
    insert into public.mo_orders (
      order_no, order_date, supplier_id, contract_id, receiver_id, project_id,
      usage_location, notes, vat_rate, subtotal, vat, total, status,
      sent_at, received_at, municipal_unit_id, study_id,
      issued_at, issued_by, created_by
    ) values (
      null, p_order_date, v_contract.supplier_id, v_contract.id, v_receiver_id, null,
      btrim(p_usage_location), nullif(btrim(coalesce(p_notes, '')), ''),
      p_vat_rate, v_subtotal, v_vat, v_total, 'draft',
      null, null, v_study.municipal_unit_id, v_study.id,
      null, null, auth.uid()
    ) returning * into v_order;
    v_order_id := v_order.id;
  else
    update public.mo_orders o
    set order_no = null,
        order_date = p_order_date,
        supplier_id = v_contract.supplier_id,
        contract_id = v_contract.id,
        receiver_id = v_receiver_id,
        project_id = null,
        usage_location = btrim(p_usage_location),
        notes = nullif(btrim(coalesce(p_notes, '')), ''),
        vat_rate = p_vat_rate,
        subtotal = v_subtotal,
        vat = v_vat,
        total = v_total,
        status = 'draft',
        sent_at = null,
        received_at = null,
        issued_at = null,
        issued_by = null,
        cancelled_at = null,
        cancelled_by = null,
        cancellation_reason = null
    where o.id = v_before.id
    returning * into v_order;
    v_order_id := v_order.id;
    delete from public.mo_order_items i where i.order_id = v_order_id;
  end if;

  for v_item in select value from jsonb_array_elements(v_normalized)
  loop
    if nullif(v_item ->> 'contract_item_id', '') is not null then
      select * into v_ci
      from public.mo_contract_items i
      where i.id::text = v_item ->> 'contract_item_id' and i.contract_id = v_contract.id;
    end if;
    insert into public.mo_order_items (
      order_id, contract_item_id, is_custom, mapping,
      description, unit, quantity, unit_price, line_total
    ) values (
      v_order_id,
      case when nullif(v_item ->> 'contract_item_id', '') is null then null else v_ci.id end,
      coalesce((v_item ->> 'is_custom')::boolean, false),
      case when jsonb_typeof(v_item -> 'mapping') = 'array' then v_item -> 'mapping' else null end,
      v_item ->> 'description', v_item ->> 'unit',
      (v_item ->> 'quantity')::numeric,
      (v_item ->> 'unit_price')::numeric,
      (v_item ->> 'line_total')::numeric
    );
  end loop;

  if coalesce(p_issue, false) then
    select coalesce(g.domain, 'procurement') into v_domain
    from public.procurement_groups g where g.id = v_study.group_id;
    v_year := extract(year from p_order_date)::integer;
    v_scope := 'mo-' || v_year || '-u' || v_study.municipal_unit_id || '-' || v_domain;
    v_sequence := public.app_next_order_sequence(v_scope);
    v_prefix := case when v_domain = 'service' then 'ΔΕ' else 'ΔΥ' end;
    v_order_no := v_prefix || '-' || v_year || '-' || lpad(v_study.municipal_unit_id::text, 2, '0') || '-' || lpad(v_sequence::text, 3, '0');

    update public.mo_orders o
    set order_no = v_order_no,
        status = 'issued',
        issued_at = now(),
        issued_by = auth.uid()
    where o.id = v_order_id
    returning * into v_order;
  end if;

  perform public.app_write_audit(
    case when coalesce(p_issue, false) then 'order_issued' else 'order_draft_saved' end,
    'mo_orders', v_order_id::text, v_study.municipal_unit_id::bigint, null,
    case when v_is_new then null else to_jsonb(v_before) end,
    jsonb_build_object(
      'order_no', v_order.order_no, 'status', v_order.status,
      'subtotal', v_subtotal, 'vat', v_vat, 'total', v_total,
      'items', v_normalized
    ),
    jsonb_build_object('study_id', v_study.id::text, 'contract_id', v_contract.id::text)
  );

  return jsonb_build_object(
    'order_id', v_order_id::text,
    'order_no', v_order.order_no,
    'status', v_order.status,
    'subtotal', v_subtotal,
    'vat', v_vat,
    'total', v_total
  );
end;
$$;

revoke all on function public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean)
  from public, anon;
grant execute on function public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean)
  to authenticated;

create or replace function public.transition_order_status_atomic(
  p_order_id text,
  p_target_status text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_before public.mo_orders%rowtype;
  v_after public.mo_orders%rowtype;
begin
  select * into v_before
  from public.mo_orders o
  where o.id::text = p_order_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε το δελτίο.'; end if;

  if p_target_status = 'cancelled' then
    if not public.app_is_admin() then
      raise exception using errcode = '42501', message = 'Μόνο διαχειριστής μπορεί να ακυρώσει εκδοθέν δελτίο.';
    end if;
    if nullif(btrim(coalesce(p_reason, '')), '') is null then
      raise exception 'Η ακύρωση απαιτεί υποχρεωτική αιτιολογία.';
    end if;
    if v_before.status not in ('issued', 'sent', 'received') then
      raise exception 'Μόνο εκδοθέν, απεσταλμένο ή παραληφθέν δελτίο μπορεί να ακυρωθεί.';
    end if;
    update public.mo_orders o
    set status = 'cancelled',
        cancelled_at = now(),
        cancelled_by = auth.uid(),
        cancellation_reason = btrim(p_reason)
    where o.id = v_before.id
    returning * into v_after;
  else
    if not public.app_can_write_unit(v_before.municipal_unit_id::bigint) then
      raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα μεταβολής του δελτίου.';
    end if;
    if p_target_status = 'sent' and v_before.status = 'issued' then
      update public.mo_orders o
      set status = 'sent', sent_at = now()
      where o.id = v_before.id returning * into v_after;
    elsif p_target_status = 'received' and v_before.status = 'sent' then
      update public.mo_orders o
      set status = 'received', received_at = now()
      where o.id = v_before.id returning * into v_after;
    else
      raise exception 'Μη επιτρεπτή μετάβαση από % σε %.', v_before.status, p_target_status;
    end if;
  end if;

  perform public.app_write_audit(
    'order_status_changed', 'mo_orders', v_before.id::text,
    v_before.municipal_unit_id::bigint,
    case when p_target_status = 'cancelled' then p_reason else null end,
    jsonb_build_object('status', v_before.status),
    jsonb_build_object('status', v_after.status),
    jsonb_build_object('order_no', v_before.order_no, 'study_id', v_before.study_id::text)
  );

  return jsonb_build_object(
    'order_id', v_after.id::text,
    'order_no', v_after.order_no,
    'status', v_after.status
  );
end;
$$;

revoke all on function public.transition_order_status_atomic(text,text,text) from public, anon;
grant execute on function public.transition_order_status_atomic(text,text,text) to authenticated;

create or replace function public.delete_order_draft_atomic(p_order_id text)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_order public.mo_orders%rowtype;
begin
  select * into v_order
  from public.mo_orders o
  where o.id::text = p_order_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε το πρόχειρο δελτίο.'; end if;
  if v_order.status <> 'draft' then
    raise exception 'Εκδοθέν δελτίο δεν διαγράφεται. Επιτρέπεται μόνο ακύρωση με αιτιολογία.';
  end if;
  if not public.app_can_write_unit(v_order.municipal_unit_id::bigint)
     or (not public.app_is_admin() and v_order.created_by is distinct from auth.uid()) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα διαγραφής του συγκεκριμένου προχείρου.';
  end if;

  perform public.app_write_audit(
    'order_draft_deleted', 'mo_orders', v_order.id::text,
    v_order.municipal_unit_id::bigint, null, to_jsonb(v_order), null,
    jsonb_build_object('study_id', v_order.study_id::text)
  );

  delete from public.mo_order_items i where i.order_id = v_order.id;
  delete from public.mo_orders o where o.id = v_order.id;
  return true;
end;
$$;

revoke all on function public.delete_order_draft_atomic(text) from public, anon;
grant execute on function public.delete_order_draft_atomic(text) to authenticated;

comment on function public.lock_study_atomic(text,bigint,bigint,integer,text,text,text,jsonb) is
  'Ατομικό κλείδωμα με server-side έλεγχο ενεργής ομάδας Δ.Ε. και κοινού ορίου.';
comment on function public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean) is
  'Ατομική αποθήκευση/έκδοση δελτίου με server-side έλεγχο αξίας και συμβατικών ποσοτήτων.';

commit;
