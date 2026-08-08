-- v36.5.5 hotfix — Διόρθωση αποθήκευσης δελτίου όταν
-- public.unit_requests.status είναι enum public.request_status.
--
-- Ασφαλές για το ήδη εγκατεστημένο staging: δεν αλλάζει πίνακες ή δεδομένα,
-- αλλά αντικαθιστά μόνο τη save_unit_request_atomic με σωστή τυποποίηση.

begin;

do $$
declare
  v_version text;
  v_status_type oid;
begin
  if to_regprocedure('public.app_schema_version()') is null then
    raise exception 'Η εφαρμογή δεν είναι εγκατεστημένη σε αυτό το project.';
  end if;

  select public.app_schema_version() into v_version;
  if v_version <> '36.5.5' then
    raise exception 'Το hotfix απαιτεί schema 36.5.5, βρέθηκε %.', v_version;
  end if;

  select a.atttypid
  into v_status_type
  from pg_attribute a
  where a.attrelid = 'public.unit_requests'::regclass
    and a.attname = 'status'
    and a.attnum > 0
    and not a.attisdropped;

  if v_status_type is distinct from 'public.request_status'::regtype::oid then
    raise exception 'Η στήλη public.unit_requests.status δεν έχει τον αναμενόμενο τύπο public.request_status.';
  end if;
end;
$$;

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

commit;
