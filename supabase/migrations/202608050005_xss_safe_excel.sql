begin;

-- v36.4 / Βήμα 4
-- Κάθε εισαγωγή Excel απαιτεί δελτίο προέλευσης που εκδίδεται από τη βάση,
-- δεσμεύεται στη Δ.Ε./ομάδα/έτος/έκδοση καταλόγου και καταναλώνεται μία φορά.

create table if not exists public.app_excel_import_tokens (
  token uuid primary key default gen_random_uuid(),
  issued_by uuid not null references auth.users(id),
  municipal_unit_id bigint not null references public.municipal_units(id),
  group_id bigint not null references public.procurement_groups(id),
  request_year integer not null check (request_year between 2000 and 2200),
  catalog_count integer not null check (catalog_count between 0 and 5000),
  issued_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users(id),
  check (expires_at > issued_at)
);

-- Το πλήρες schema v2 χρησιμοποιεί UUID για τα αιτήματα, ενώ παλαιότερες
-- εγκαταστάσεις μπορεί να έχουν bigint. Το FK δημιουργείται με τον πραγματικό
-- τύπο του public.unit_requests.id, ώστε η migration να είναι ασφαλής και στις
-- δύο περιπτώσεις χωρίς μετατροπή ή απώλεια αναγνωριστικών.
do $$
declare
  v_request_id_type text;
begin
  select format_type(a.atttypid, a.atttypmod)
  into v_request_id_type
  from pg_attribute a
  where a.attrelid = 'public.unit_requests'::regclass
    and a.attname = 'id'
    and a.attnum > 0
    and not a.attisdropped;

  if v_request_id_type is null then
    raise exception 'Δεν βρέθηκε ο τύπος του public.unit_requests.id.';
  end if;

  if not exists (
    select 1
    from pg_attribute a
    where a.attrelid = 'public.app_excel_import_tokens'::regclass
      and a.attname = 'used_request_id'
      and a.attnum > 0
      and not a.attisdropped
  ) then
    execute format(
      'alter table public.app_excel_import_tokens add column used_request_id %s references public.unit_requests(id)',
      v_request_id_type
    );
  end if;

  if not exists (
    select 1
    from pg_constraint c
    where c.conrelid = 'public.app_excel_import_tokens'::regclass
      and c.conname = 'app_excel_import_tokens_usage_consistency'
  ) then
    alter table public.app_excel_import_tokens
      add constraint app_excel_import_tokens_usage_consistency
      check (
        (used_at is null and used_by is null and used_request_id is null)
        or (used_at is not null and used_by is not null and used_request_id is not null)
      );
  end if;
end;
$$;

create index if not exists app_excel_import_tokens_expiry_idx
  on public.app_excel_import_tokens (expires_at) where used_at is null;
create index if not exists app_excel_import_tokens_context_idx
  on public.app_excel_import_tokens (municipal_unit_id, group_id, request_year, issued_at desc);

alter table public.app_excel_import_tokens enable row level security;
revoke all on table public.app_excel_import_tokens from public, anon, authenticated;

create or replace function public.app_excel_import_text_valid(p_value text, p_max_length integer)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select p_value is null
    or (
      p_max_length between 1 and 20000
      and char_length(p_value) <= p_max_length
      and p_value !~ E'[\\x01-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]'
      and not exists (
        select 1
        from unnest(array[8234,8235,8236,8237,8238,8294,8295,8296,8297]) as blocked(codepoint)
        where strpos(p_value, chr(blocked.codepoint)) > 0
      )
    )
$$;

revoke all on function public.app_excel_import_text_valid(text,integer) from public, anon, authenticated;

create or replace function public.issue_excel_export_token(
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_catalog_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_token uuid;
  v_expires_at timestamptz := now() + interval '7 days';
  v_actual_count integer;
begin
  if not public.app_can_read_unit(p_municipal_unit_id) then
    raise exception using errcode = '42501', message = 'Δεν έχετε δικαίωμα εξαγωγής για τη συγκεκριμένη Δημοτική Ενότητα.';
  end if;
  if p_request_year not between 2000 and 2200 then
    raise exception 'Μη έγκυρο έτος εξαγωγής Excel.';
  end if;
  if not exists (select 1 from public.municipal_units u where u.id::bigint = p_municipal_unit_id)
     or not exists (select 1 from public.procurement_groups g where g.id::bigint = p_group_id) then
    raise exception 'Η Δημοτική Ενότητα ή η ομάδα Excel δεν υπάρχει.';
  end if;

  select count(*)::integer into v_actual_count
  from public.materials m
  where m.group_id::bigint = p_group_id and m.is_active is true;

  if p_catalog_count is null or p_catalog_count <> v_actual_count or p_catalog_count > 5000 then
    raise exception 'Ο κατάλογος άλλαξε κατά την εξαγωγή. Ανανεώστε την εφαρμογή και εξαγάγετε ξανά το Excel.';
  end if;

  insert into public.app_excel_import_tokens (
    issued_by, municipal_unit_id, group_id, request_year, catalog_count, expires_at
  ) values (
    auth.uid(), p_municipal_unit_id, p_group_id, p_request_year, p_catalog_count, v_expires_at
  ) returning token into v_token;

  return jsonb_build_object(
    'token', v_token::text,
    'issued_at', now(),
    'expires_at', v_expires_at,
    'single_use', true
  );
end;
$$;

revoke all on function public.issue_excel_export_token(bigint,bigint,integer,integer)
  from public, anon;
grant execute on function public.issue_excel_export_token(bigint,bigint,integer,integer)
  to authenticated;

create or replace function public.secure_import_catalog_request_atomic(
  p_import_token uuid,
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
  v_ticket public.app_excel_import_tokens%rowtype;
  v_item jsonb;
  v_patch jsonb;
  v_result jsonb;
  v_actual_count integer;
  v_request_id public.unit_requests.id%type;
begin
  if not public.app_is_admin() then
    raise exception using errcode = '42501', message = 'Η ασφαλής εισαγωγή Excel επιτρέπεται μόνο σε διαχειριστή.';
  end if;
  if p_import_token is null then
    raise exception 'Λείπει το δελτίο προέλευσης του Excel.';
  end if;

  select t.* into v_ticket
  from public.app_excel_import_tokens t
  where t.token = p_import_token
  for update;

  if v_ticket.token is null then
    raise exception 'Το δελτίο προέλευσης του Excel δεν υπάρχει.';
  end if;
  if v_ticket.used_at is not null then
    raise exception 'Το δελτίο προέλευσης του Excel έχει ήδη χρησιμοποιηθεί.';
  end if;
  if v_ticket.issued_by <> auth.uid() then
    raise exception using errcode = '42501', message = 'Το δελτίο προέλευσης του Excel ανήκει σε διαφορετικό χρήστη.';
  end if;
  if v_ticket.expires_at <= now() then
    raise exception 'Το δελτίο προέλευσης του Excel έχει λήξει.';
  end if;
  if v_ticket.municipal_unit_id <> p_municipal_unit_id
     or v_ticket.group_id <> p_group_id
     or v_ticket.request_year <> p_request_year then
    raise exception 'Το δελτίο προέλευσης δεν αντιστοιχεί στη Δ.Ε., ομάδα ή έτος της εισαγωγής.';
  end if;

  select count(*)::integer into v_actual_count
  from public.materials m
  where m.group_id::bigint = p_group_id and m.is_active is true;
  if v_actual_count <> v_ticket.catalog_count then
    raise exception 'Ο κεντρικός κατάλογος άλλαξε μετά την εξαγωγή. Εξαγάγετε νέο Excel.';
  end if;

  if not public.app_excel_import_text_valid(p_title, 500) then
    raise exception 'Ο τίτλος της εισαγωγής υπερβαίνει το επιτρεπτό μήκος ή περιέχει χαρακτήρες ελέγχου.';
  end if;
  if p_material_updates is null or jsonb_typeof(p_material_updates) <> 'array'
     or p_new_materials is null or jsonb_typeof(p_new_materials) <> 'array'
     or p_lines is null or jsonb_typeof(p_lines) <> 'array' then
    raise exception 'Τα δεδομένα εισαγωγής πρέπει να είναι πίνακες JSON.';
  end if;
  if jsonb_array_length(p_material_updates) + jsonb_array_length(p_new_materials) > 5000
     or jsonb_array_length(p_lines) > 5000 then
    raise exception 'Η εισαγωγή υπερβαίνει το όριο των 5.000 γραμμών.';
  end if;

  for v_item in select value from jsonb_array_elements(p_material_updates)
  loop
    v_patch := coalesce(v_item -> 'patch', '{}'::jsonb);
    if jsonb_typeof(v_patch) <> 'object'
       or not public.app_excel_import_text_valid(v_patch ->> 'name', 500)
       or not public.app_excel_import_text_valid(v_patch ->> 'short_name', 500)
       or not public.app_excel_import_text_valid(v_patch ->> 'unit', 50)
       or not public.app_excel_import_text_valid(v_patch ->> 'cpv', 120)
       or not public.app_excel_import_text_valid(v_patch ->> 'technical_specs', 12000)
       or not public.app_excel_import_text_valid(v_patch ->> 'subcategory', 500)
       or not public.app_excel_import_text_valid(v_patch ->> 'standards', 4000)
       or not public.app_excel_import_text_valid(v_patch ->> 'notes_for_tender', 4000) then
      raise exception 'Μη έγκυρο ή υπερβολικά μεγάλο κείμενο σε ενημέρωση είδους Excel.';
    end if;
    if v_patch ? 'default_unit_price'
       and jsonb_typeof(v_patch -> 'default_unit_price') <> 'null'
       and ((v_patch ->> 'default_unit_price')::numeric < 0
         or (v_patch ->> 'default_unit_price')::numeric > 1000000000) then
      raise exception 'Μη επιτρεπτή τιμή μονάδας σε ενημέρωση είδους Excel.';
    end if;
  end loop;

  for v_item in select value from jsonb_array_elements(p_new_materials)
  loop
    if not public.app_excel_import_text_valid(v_item ->> 'code', 120)
       or not public.app_excel_import_text_valid(v_item ->> 'name', 500)
       or not public.app_excel_import_text_valid(v_item ->> 'short_name', 500)
       or not public.app_excel_import_text_valid(v_item ->> 'unit', 50)
       or not public.app_excel_import_text_valid(v_item ->> 'cpv', 120)
       or not public.app_excel_import_text_valid(v_item ->> 'technical_specs', 12000)
       or not public.app_excel_import_text_valid(v_item ->> 'subcategory', 500)
       or not public.app_excel_import_text_valid(v_item ->> 'standards', 4000)
       or not public.app_excel_import_text_valid(v_item ->> 'notes_for_tender', 4000) then
      raise exception 'Μη έγκυρο ή υπερβολικά μεγάλο κείμενο σε νέο είδος Excel.';
    end if;
    if v_item ? 'default_unit_price'
       and jsonb_typeof(v_item -> 'default_unit_price') <> 'null'
       and ((v_item ->> 'default_unit_price')::numeric < 0
         or (v_item ->> 'default_unit_price')::numeric > 1000000000) then
      raise exception 'Μη επιτρεπτή τιμή μονάδας σε νέο είδος Excel.';
    end if;
  end loop;

  v_result := public.import_catalog_request_atomic(
    p_request_id, p_municipal_unit_id, p_group_id, p_request_year, p_title,
    p_material_updates, p_new_materials, p_lines
  );
  select r.id
  into v_request_id
  from public.unit_requests r
  where r.id::text = nullif(v_result ->> 'request_id', '');

  if v_request_id is null then
    raise exception 'Η εισαγωγή ολοκληρώθηκε χωρίς έγκυρο αναγνωριστικό αιτήματος.';
  end if;

  update public.app_excel_import_tokens t
  set used_at = now(), used_by = auth.uid(), used_request_id = v_request_id
  where t.token = p_import_token;

  perform public.app_write_audit(
    'excel_import_token_consumed', 'unit_requests', v_request_id::text,
    p_municipal_unit_id, null, null,
    jsonb_build_object('single_use_token_consumed', true),
    jsonb_build_object('group_id', p_group_id, 'request_year', p_request_year)
  );

  return v_result || jsonb_build_object('secure_import', true);
end;
$$;

-- Από τη v36.4 το παλιό RPC δεν είναι πλέον άμεσα προσβάσιμο από browser.
revoke all on function public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  from public, anon, authenticated;
revoke all on function public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  from public, anon;
grant execute on function public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
  to authenticated;

create or replace function public.app_schema_version()
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select '36.4'::text
$$;

revoke all on function public.app_schema_version() from public, anon;
grant execute on function public.app_schema_version() to authenticated;

comment on table public.app_excel_import_tokens is
  'Δελτία προέλευσης μιας χρήσης για ασφαλή επανεισαγωγή Excel, δεσμευμένα σε Δ.Ε./ομάδα/έτος/έκδοση καταλόγου.';
comment on function public.secure_import_catalog_request_atomic(uuid,text,bigint,bigint,integer,text,jsonb,jsonb,jsonb) is
  'Ατομική εισαγωγή Excel v36.4 με έλεγχο και κατανάλωση server-side δελτίου προέλευσης.';

commit;
