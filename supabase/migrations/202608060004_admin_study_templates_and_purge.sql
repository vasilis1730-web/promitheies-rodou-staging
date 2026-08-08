-- v36.6.0 — Διαχείριση κλειδωμένων μελετών από administrator.
--
-- Προσθέτει:
--   * ανεξάρτητα πρότυπα μελετών,
--   * φόρτωση προτύπου ως κανονικό επεξεργάσιμο πρόχειρο,
--   * συναλλακτική, πλήρη διαγραφή κλειδωμένης μελέτης αποκλειστικά από admin.
--
-- Η πλήρης διαγραφή είναι σκόπιμα διαφορετική από την «Ακύρωση»: αφαιρεί
-- τη μελέτη, τις αναθέσεις, τα δελτία, τις γραμμές τους και κάθε εσωτερική
-- εγγραφή ιστορικού που περιέχει το UUID της μελέτης. Τα κοινόχρηστα μητρώα
-- προμηθευτών/αναδόχων και παραλαμβανόντων δεν διαγράφονται.

begin;

select pg_advisory_xact_lock(hashtext('promitheies_rodou_v36_6_0_admin_study_management'));

do $$
declare
  v_version text;
begin
  if to_regprocedure('public.app_schema_version()') is null then
    raise exception 'Λείπει η public.app_schema_version(). Εφαρμόστε πρώτα όλες τις migrations της v36.5.5.';
  end if;
  select public.app_schema_version() into v_version;
  if v_version not in ('36.5.5', '36.6.0') then
    raise exception 'Η migration διαχείρισης μελετών απαιτεί schema 36.5.5. Βρέθηκε: %', coalesce(v_version, 'NULL');
  end if;
  if to_regprocedure('public.app_is_admin()') is null
     or to_regprocedure('public.app_can_write_unit(bigint)') is null
     or to_regprocedure('public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)') is null then
    raise exception 'Λείπουν απαιτούμενες ατομικές συναρτήσεις της v36.5.5.';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'mo_orders' and column_name = 'study_id'
  ) then
    raise exception 'Απαιτείται πρώτα το 202608060003_fix_mo_orders_study_column.sql.';
  end if;
end;
$$;

create table if not exists public.study_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 3 and 140),
  description text null check (description is null or char_length(description) <= 1000),
  domain text not null check (domain in ('procurement', 'service')),
  group_id bigint not null references public.procurement_groups(id) on delete restrict,
  source_study_id uuid null references public.locked_studies(id) on delete set null,
  source_municipal_unit_id bigint null references public.municipal_units(id) on delete set null,
  source_request_year integer null,
  source_study_seq integer null,
  lines jsonb not null check (jsonb_typeof(lines) = 'array'),
  item_count integer not null default 0 check (item_count >= 0),
  net_total numeric(14,2) not null default 0 check (net_total >= 0),
  is_active boolean not null default true,
  created_by uuid null references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_by uuid null references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_study_templates_group_name
  on public.study_templates (group_id, lower(btrim(name)));
create index if not exists idx_study_templates_group_active
  on public.study_templates (group_id, is_active, updated_at desc);
create index if not exists idx_study_templates_source_study
  on public.study_templates (source_study_id)
  where source_study_id is not null;

alter table public.study_templates enable row level security;
revoke all on table public.study_templates from public, anon, authenticated;
grant select on table public.study_templates to authenticated;
drop policy if exists study_templates_select_authenticated on public.study_templates;
create policy study_templates_select_authenticated on public.study_templates
  for select to authenticated
  using (auth.uid() is not null and is_active is true);

-- Η ρύθμιση είναι transaction-local και ενεργοποιείται μόνο μέσα στην
-- SECURITY DEFINER RPC της πλήρους διαγραφής. Ακόμη κι αν κάποιος ορίσει
-- ομώνυμο GUC, οι guards απαιτούν ταυτόχρονα πραγματικό ρόλο admin.
create or replace function public.app_admin_purge_mode()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
set row_security = off
as $$
  select coalesce(current_setting('app.admin_purge_mode', true), '') = 'on'
     and public.app_is_admin()
$$;

revoke all on function public.app_admin_purge_mode() from public, anon, authenticated;

-- Τα υπάρχοντα αμετάβλητα ιστορικά εξακολουθούν να προστατεύονται. Μοναδική
-- εξαίρεση είναι η εσωτερική συναλλαγή πλήρους διαγραφής από administrator.
create or replace function public.app_immutable_history_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' and public.app_admin_purge_mode() then
    return old;
  end if;
  raise exception using
    errcode = '55000',
    message = 'Η εγγραφή αποτελεί αμετάβλητο ιστορικό και δεν επιτρέπεται να τροποποιηθεί ή να διαγραφεί.';
end;
$$;

create or replace function public.app_locked_study_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if public.app_admin_purge_mode() then return old; end if;
    raise exception using
      errcode = '55000',
      message = 'Η κλειδωμένη μελέτη δεν διαγράφεται απευθείας. Χρησιμοποιήστε ακύρωση ή την ειδική πλήρη διαγραφή administrator.';
  end if;

  if (
    to_jsonb(new) - array[
      'supplier_name', 'kimdis_url', 'record_status', 'award_group_id',
      'cancelled_at', 'cancelled_by', 'cancellation_reason'
    ]::text[]
  ) is distinct from (
    to_jsonb(old) - array[
      'supplier_name', 'kimdis_url', 'record_status', 'award_group_id',
      'cancelled_at', 'cancelled_by', 'cancellation_reason'
    ]::text[]
  ) then
    raise exception using
      errcode = '55000',
      message = 'Τα οικονομικά στοιχεία και το στιγμιότυπο κλειδωμένης μελέτης είναι αμετάβλητα.';
  end if;

  if new.award_group_id is distinct from old.award_group_id and not (
    old.award_group_id is null
    and new.award_group_id is not null
    and public.app_is_admin()
    and exists (
      select 1
      from public.award_group_configurations c
      join public.award_group_memberships m on m.configuration_id = c.id
      where c.budget_year = old.request_year
        and c.is_active
        and m.municipal_unit_id = old.municipal_unit_id
        and m.award_group_id = new.award_group_id
    )
  ) then
    raise exception using
      errcode = '55000',
      message = 'Η ομάδα Δημοτικών Ενοτήτων κλειδωμένης μελέτης δεν αλλάζει.';
  end if;

  if old.record_status = 'cancelled' then
    raise exception using errcode = '55000', message = 'Ακυρωμένη κλειδωμένη μελέτη δεν μεταβάλλεται.';
  end if;
  if new.record_status not in ('active', 'cancelled') then
    raise exception 'Μη επιτρεπτή κατάσταση κλειδωμένης μελέτης.';
  end if;
  if new.record_status = 'cancelled' and (
    new.cancelled_at is null or new.cancelled_by is null
    or nullif(btrim(coalesce(new.cancellation_reason, '')), '') is null
  ) then
    raise exception 'Η ακύρωση απαιτεί χρόνο, χρήστη και αιτιολογία.';
  end if;
  return new;
end;
$$;

create or replace function public.app_order_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if public.app_admin_purge_mode() then return old; end if;
    if old.status <> 'draft' then
      raise exception using
        errcode = '55000',
        message = 'Εκδοθέν δελτίο δεν διαγράφεται. Επιτρέπεται μόνο ακύρωση με αιτιολογία.';
    end if;
    return old;
  end if;

  if old.status <> 'draft' and (
    to_jsonb(new) - array[
      'status', 'sent_at', 'received_at',
      'cancelled_at', 'cancelled_by', 'cancellation_reason'
    ]::text[]
  ) is distinct from (
    to_jsonb(old) - array[
      'status', 'sent_at', 'received_at',
      'cancelled_at', 'cancelled_by', 'cancellation_reason'
    ]::text[]
  ) then
    raise exception using errcode = '55000', message = 'Το περιεχόμενο εκδοθέντος δελτίου είναι αμετάβλητο.';
  end if;

  if new.status is distinct from old.status and not (
    (old.status = 'draft' and new.status = 'issued')
    or (old.status = 'issued' and new.status in ('sent', 'cancelled'))
    or (old.status = 'sent' and new.status in ('received', 'cancelled'))
    or (old.status = 'received' and new.status = 'cancelled')
  ) then
    raise exception 'Μη επιτρεπτή μετάβαση δελτίου από % σε %.', old.status, new.status;
  end if;
  if new.status = 'cancelled' and (
    new.cancelled_at is null or new.cancelled_by is null
    or nullif(btrim(coalesce(new.cancellation_reason, '')), '') is null
  ) then
    raise exception 'Η ακύρωση δελτίου απαιτεί χρόνο, χρήστη και αιτιολογία.';
  end if;
  return new;
end;
$$;

create or replace function public.app_order_item_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_order_id text;
  v_status text;
begin
  if tg_op = 'DELETE' and public.app_admin_purge_mode() then return old; end if;
  v_order_id := case when tg_op = 'DELETE' then old.order_id::text else new.order_id::text end;
  select o.status into v_status from public.mo_orders o where o.id::text = v_order_id;
  if v_status is distinct from 'draft' then
    raise exception using errcode = '55000', message = 'Οι γραμμές εκδοθέντος δελτίου είναι αμετάβλητες.';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.app_contract_item_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' and public.app_admin_purge_mode() then return old; end if;
  raise exception using
    errcode = '55000',
    message = 'Το αρχικό τιμολόγιο της ανάθεσης αποτελεί αμετάβλητο στιγμιότυπο της κλειδωμένης μελέτης.';
end;
$$;

create or replace function public.app_contract_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if tg_op = 'DELETE' then
    if public.app_admin_purge_mode() then return old; end if;
    raise exception using errcode = '55000', message = 'Η ανάθεση δεν διαγράφεται. Απαιτείται ελεγχόμενη διοικητική μεταβολή.';
  end if;
  if (
    to_jsonb(new) - array[
      'supplier_id', 'adam', 'protocol_no', 'start_date', 'end_date',
      'active', 'updated_at', 'updated_by'
    ]::text[]
  ) is distinct from (
    to_jsonb(old) - array[
      'supplier_id', 'adam', 'protocol_no', 'start_date', 'end_date',
      'active', 'updated_at', 'updated_by'
    ]::text[]
  ) then
    raise exception using
      errcode = '55000',
      message = 'Η πηγή, η Δημοτική Ενότητα και το οικονομικό αντικείμενο της ανάθεσης είναι αμετάβλητα.';
  end if;
  return new;
end;
$$;

create or replace function public.save_locked_study_as_template_atomic(
  p_study_id text,
  p_name text,
  p_description text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_study public.locked_studies%rowtype;
  v_template public.study_templates%rowtype;
  v_domain text;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο administrator μπορεί να αποθηκεύσει κλειδωμένη μελέτη ως πρότυπο.';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 3 and 140 then
    raise exception 'Η ονομασία προτύπου πρέπει να έχει από 3 έως 140 χαρακτήρες.';
  end if;
  if char_length(coalesce(p_description, '')) > 1000 then
    raise exception 'Η περιγραφή προτύπου δεν μπορεί να υπερβαίνει τους 1.000 χαρακτήρες.';
  end if;

  select * into v_study
  from public.locked_studies s
  where s.id::text = p_study_id
  for share;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;

  select coalesce(g.domain, 'procurement') into v_domain
  from public.procurement_groups g where g.id = v_study.group_id;

  insert into public.study_templates (
    name, description, domain, group_id, source_study_id,
    source_municipal_unit_id, source_request_year, source_study_seq,
    lines, item_count, net_total, created_by, updated_by
  ) values (
    btrim(p_name), nullif(btrim(coalesce(p_description, '')), ''), v_domain,
    v_study.group_id, v_study.id, v_study.municipal_unit_id,
    v_study.request_year, v_study.seq, v_study.lines,
    v_study.item_count, v_study.net_total, auth.uid(), auth.uid()
  ) returning * into v_template;

  perform public.app_write_audit(
    'study_template_created', 'study_templates', v_template.id::text,
    v_study.municipal_unit_id::bigint, null, null,
    jsonb_build_object('name', v_template.name, 'group_id', v_template.group_id,
      'item_count', v_template.item_count, 'net_total', v_template.net_total),
    jsonb_build_object('source_study_id', v_study.id::text, 'source_seq', v_study.seq)
  );

  return jsonb_build_object(
    'template_id', v_template.id::text, 'name', v_template.name,
    'item_count', v_template.item_count, 'net_total', v_template.net_total
  );
exception
  when unique_violation then
    raise exception 'Υπάρχει ήδη πρότυπο με αυτή την ονομασία στην ίδια ομάδα.';
end;
$$;

create or replace function public.load_study_template_atomic(
  p_template_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_template public.study_templates%rowtype;
  v_request_id public.unit_requests.id%type;
  v_payload jsonb;
  v_total integer;
  v_loaded integer;
  v_result jsonb;
begin
  if not public.app_can_write_unit(p_municipal_unit_id) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα φόρτωσης προτύπου στη συγκεκριμένη Δημοτική Ενότητα.';
  end if;
  if p_request_year not between 2000 and 2200 then raise exception 'Μη έγκυρο έτος μελέτης.'; end if;

  select * into v_template
  from public.study_templates t
  where t.id::text = p_template_id and t.is_active is true;
  if not found then raise exception 'Δεν βρέθηκε ενεργό πρότυπο.'; end if;
  if v_template.group_id::bigint <> p_group_id then
    raise exception 'Το πρότυπο ανήκει σε διαφορετική ομάδα υλικών ή υπηρεσιών.';
  end if;

  v_total := jsonb_array_length(v_template.lines);
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'material_id', m.id::text,
      'quantity', greatest(0, coalesce((x.value ->> 'quantity')::numeric, 0)),
      'unit_price', greatest(0, coalesce((x.value ->> 'unit_price')::numeric, m.default_unit_price, 0)),
      'comments', null
    ) order by coalesce(m.sort_order, 0), m.id
  ), '[]'::jsonb), count(*)::integer
  into v_payload, v_loaded
  from jsonb_array_elements(v_template.lines) x(value)
  join public.materials m
    on m.id::text = x.value ->> 'material_id'
   and m.group_id::bigint = p_group_id
   and m.is_active is true
  where coalesce((x.value ->> 'quantity')::numeric, 0) > 0;

  if v_loaded = 0 then
    raise exception 'Κανένα είδος ή εργασία του προτύπου δεν υπάρχει πλέον στον ενεργό κατάλογο.';
  end if;

  select r.id into v_request_id
  from public.unit_requests r
  where r.municipal_unit_id::bigint = p_municipal_unit_id
    and r.group_id::bigint = p_group_id
    and r.request_year = p_request_year;

  select public.save_unit_request_atomic(
    case when v_request_id is null then null else v_request_id::text end,
    p_municipal_unit_id, p_group_id, p_request_year,
    'Μελέτη από πρότυπο: ' || v_template.name,
    'save', v_payload
  ) into v_result;

  perform public.app_write_audit(
    'study_template_loaded', 'study_templates', v_template.id::text,
    p_municipal_unit_id, null,
    null,
    jsonb_build_object('request_id', v_result ->> 'request_id', 'request_year', p_request_year,
      'loaded_lines', v_loaded, 'skipped_lines', greatest(0, v_total - v_loaded)),
    jsonb_build_object('group_id', p_group_id)
  );

  return jsonb_build_object(
    'template_id', v_template.id::text,
    'template_name', v_template.name,
    'request_id', v_result ->> 'request_id',
    'loaded_lines', v_loaded,
    'skipped_lines', greatest(0, v_total - v_loaded)
  );
end;
$$;

create or replace function public.delete_study_template_atomic(p_template_id text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_template public.study_templates%rowtype;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο administrator μπορεί να διαγράψει πρότυπο μελέτης.';
  end if;
  delete from public.study_templates t
  where t.id::text = p_template_id
  returning * into v_template;
  if not found then raise exception 'Δεν βρέθηκε το πρότυπο μελέτης.'; end if;

  perform public.app_write_audit(
    'study_template_deleted', 'study_templates', v_template.id::text,
    v_template.source_municipal_unit_id, null,
    jsonb_build_object('name', v_template.name, 'group_id', v_template.group_id,
      'item_count', v_template.item_count, 'net_total', v_template.net_total),
    null, '{}'::jsonb
  );
  return jsonb_build_object('template_id', v_template.id::text, 'deleted', true);
end;
$$;

create or replace function public.admin_purge_locked_study_atomic(
  p_study_id text,
  p_confirmation text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_study public.locked_studies%rowtype;
  v_order_items integer := 0;
  v_orders integer := 0;
  v_contract_items integer := 0;
  v_contracts integer := 0;
  v_versions integer := 0;
  v_exports integer := 0;
  v_audits integer := 0;
  v_templates_detached integer := 0;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Μόνο administrator μπορεί να εκτελέσει πλήρη διαγραφή κλειδωμένης μελέτης.';
  end if;
  if upper(btrim(coalesce(p_confirmation, ''))) <> 'ΔΙΑΓΡΑΦΗ' then
    raise exception 'Η πλήρης διαγραφή απαιτεί την επιβεβαίωση «ΔΙΑΓΡΑΦΗ».';
  end if;

  select * into v_study
  from public.locked_studies s
  where s.id::text = p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;

  perform set_config('app.admin_purge_mode', 'on', true);

  -- Το πρότυπο είναι αυτοτελές και δεν χάνεται μαζί με την πηγή του.
  update public.study_templates t
  set source_study_id = null,
      updated_at = now(),
      updated_by = auth.uid()
  where t.source_study_id = v_study.id;
  get diagnostics v_templates_detached = row_count;

  delete from public.saved_versions v
  where position(v_study.id::text in coalesce(v.snapshot::text, '')) > 0;
  get diagnostics v_versions = row_count;

  delete from public.export_jobs e
  where position(v_study.id::text in coalesce(e.payload::text, '')) > 0;
  get diagnostics v_exports = row_count;

  delete from public.app_audit_log a
  where a.entity_id = v_study.id::text
     or position(v_study.id::text in coalesce(a.before_data::text, '')) > 0
     or position(v_study.id::text in coalesce(a.after_data::text, '')) > 0
     or position(v_study.id::text in coalesce(a.metadata::text, '')) > 0;
  get diagnostics v_audits = row_count;

  delete from public.mo_order_items oi
  where oi.order_id in (
    select o.id from public.mo_orders o where o.study_id = v_study.id
  );
  get diagnostics v_order_items = row_count;

  delete from public.mo_orders o where o.study_id = v_study.id;
  get diagnostics v_orders = row_count;

  delete from public.mo_contract_items ci
  where ci.contract_id in (
    select c.id from public.mo_contracts c where c.source_study_id = v_study.id
  );
  get diagnostics v_contract_items = row_count;

  delete from public.mo_contracts c where c.source_study_id = v_study.id;
  get diagnostics v_contracts = row_count;

  delete from public.locked_studies s where s.id = v_study.id;
  if not found then raise exception 'Η κλειδωμένη μελέτη δεν διαγράφηκε.'; end if;

  perform set_config('app.admin_purge_mode', 'off', true);

  return jsonb_build_object(
    'study_id', v_study.id::text,
    'study_seq', v_study.seq,
    'municipal_unit_id', v_study.municipal_unit_id,
    'group_id', v_study.group_id,
    'request_year', v_study.request_year,
    'deleted', true,
    'deleted_order_items', v_order_items,
    'deleted_orders', v_orders,
    'deleted_contract_items', v_contract_items,
    'deleted_contracts', v_contracts,
    'deleted_saved_versions', v_versions,
    'deleted_export_jobs', v_exports,
    'deleted_audit_entries', v_audits,
    'detached_templates', v_templates_detached
  );
end;
$$;

revoke all on function public.save_locked_study_as_template_atomic(text,text,text)
  from public, anon;
revoke all on function public.load_study_template_atomic(text,bigint,bigint,integer)
  from public, anon;
revoke all on function public.delete_study_template_atomic(text)
  from public, anon;
revoke all on function public.admin_purge_locked_study_atomic(text,text)
  from public, anon;

grant execute on function public.save_locked_study_as_template_atomic(text,text,text) to authenticated;
grant execute on function public.load_study_template_atomic(text,bigint,bigint,integer) to authenticated;
grant execute on function public.delete_study_template_atomic(text) to authenticated;
grant execute on function public.admin_purge_locked_study_atomic(text,text) to authenticated;

create or replace function public.app_schema_version()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select '36.6.0'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

comment on table public.study_templates is
  'Ανεξάρτητα στιγμιότυπα κλειδωμένων μελετών, επαναχρησιμοποιήσιμα ανά ομοειδή ομάδα.';
comment on function public.admin_purge_locked_study_atomic(text,text) is
  'Admin-only πλήρης διαγραφή μελέτης και όλων των άμεσα συνδεδεμένων λειτουργικών/ιστορικών εγγραφών σε μία συναλλαγή.';
comment on function public.load_study_template_atomic(text,bigint,bigint,integer) is
  'Φορτώνει πρότυπο στο κανονικό επεξεργάσιμο δελτίο της επιλεγμένης Δ.Ε./ομάδας/έτους.';

commit;
