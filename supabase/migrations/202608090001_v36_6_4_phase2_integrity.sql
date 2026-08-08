-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — v36.6.4 PHASE 2 INTEGRITY
--
-- 1. Κλείνει το legacy Excel-import authorization bypass.
-- 2. Δελτίο: ο ΦΠΑ πρέπει να συμφωνεί με τη σύμβαση.
-- 3. Εκδοθέν/απεσταλμένο/παραληφθέν δελτίο πρέπει να βρίσκεται εντός
--    της χρονικής διάρκειας της σύμβασης, όταν έχουν οριστεί ημερομηνίες.
-- 4. Κλειδωμένη μελέτη που έχει ήδη ανάθεση/σύμβαση δεν ακυρώνεται.
-- 5. Διορθωτική μεταβολή σύμβασης δεν αλλοιώνει τον προμηθευτή ούτε
--    αποκλείει ημερομηνίες ήδη εκδοθέντων δελτίων.
-- 6. Ενιαία έκδοση schema 36.6.4.
--
-- Επαναλήψιμη. Δεν μεταβάλλει επιχειρησιακά δεδομένα.
-- ============================================================================

begin;

-- ---------------------------------------------------------------------------
-- P0: Η secure_import_catalog_request_atomic είναι το μοναδικό δημόσιο RPC
-- εισαγωγής Excel και απαιτεί administrator. Η παλαιότερη εσωτερική function
-- τροποποιεί τον κοινό κατάλογο και δεν πρέπει να είναι απευθείας καλέσιμη
-- από authenticated χρήστες.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)') is not null then
    revoke all on function public.import_catalog_request_atomic(text,bigint,bigint,integer,text,jsonb,jsonb,jsonb)
      from public, anon, authenticated;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Lifecycle invariant: από τη στιγμή που υπάρχει ανάθεση/σύμβαση, η πηγή της
-- δεν μπορεί να χαρακτηριστεί «cancelled». Η πλήρης admin purge παραμένει
-- ξεχωριστή ελεγχόμενη διαδικασία και διαγράφει πρώτα τις εξαρτήσεις.
-- ---------------------------------------------------------------------------
create or replace function public.app_study_contract_cancel_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.record_status = 'active'
     and new.record_status = 'cancelled'
     and exists (
       select 1
       from public.mo_contracts c
       where c.source_study_id = old.id
     ) then
    raise exception using
      errcode = '55000',
      message = 'Η κλειδωμένη μελέτη έχει ήδη ανάθεση/σύμβαση και δεν μπορεί να ακυρωθεί. Απαιτείται πρώτα η προβλεπόμενη διαχείριση της σύμβασης.';
  end if;
  return new;
end;
$$;

revoke all on function public.app_study_contract_cancel_guard()
  from public, anon, authenticated;

drop trigger if exists trg_locked_studies_contract_cancel_guard on public.locked_studies;
create trigger trg_locked_studies_contract_cancel_guard
  before update of record_status on public.locked_studies
  for each row execute function public.app_study_contract_cancel_guard();

-- ---------------------------------------------------------------------------
-- Αν υπάρχουν ήδη εκδοθέντα/απεσταλμένα/παραληφθέντα δελτία, η διορθωτική
-- ενημέρωση της ανάθεσης δεν μπορεί να αλλάξει αντισυμβαλλόμενο ούτε να
-- μετακινήσει την περίοδο έτσι ώστε ιστορικό δελτίο να βρεθεί εκτός σύμβασης.
-- ---------------------------------------------------------------------------
create or replace function public.app_contract_order_history_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_min_order_date date;
  v_max_order_date date;
begin
  select min(o.order_date), max(o.order_date)
  into v_min_order_date, v_max_order_date
  from public.mo_orders o
  where o.contract_id = old.id
    and o.status in ('issued', 'sent', 'received');

  if v_min_order_date is null then
    return new;
  end if;

  if new.supplier_id is distinct from old.supplier_id then
    raise exception using
      errcode = '55000',
      message = 'Δεν αλλάζει ο προμηθευτής/ανάδοχος σύμβασης που έχει ήδη εκδοθέντα δελτία.';
  end if;

  if new.start_date is not null and new.start_date > v_min_order_date then
    raise exception using
      errcode = '22008',
      message = format(
        'Η νέα έναρξη της σύμβασης %s είναι μεταγενέστερη από ήδη εκδοθέν δελτίο %s.',
        new.start_date, v_min_order_date
      );
  end if;

  if new.end_date is not null and new.end_date < v_max_order_date then
    raise exception using
      errcode = '22008',
      message = format(
        'Η νέα λήξη της σύμβασης %s προηγείται από ήδη εκδοθέν δελτίο %s.',
        new.end_date, v_max_order_date
      );
  end if;

  return new;
end;
$$;

revoke all on function public.app_contract_order_history_guard()
  from public, anon, authenticated;

drop trigger if exists trg_mo_contracts_order_history_guard on public.mo_contracts;
create trigger trg_mo_contracts_order_history_guard
  before update of supplier_id, start_date, end_date on public.mo_contracts
  for each row execute function public.app_contract_order_history_guard();

-- ---------------------------------------------------------------------------
-- Οικονομική / χρονική ακεραιότητα δελτίου ως καθολικό DB invariant.
-- Δεν βασιζόμαστε στο frontend ούτε αποκλειστικά στη save_order_atomic.
-- ---------------------------------------------------------------------------
create or replace function public.app_order_contract_integrity_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_contract public.mo_contracts%rowtype;
  v_expected_vat numeric(14,2);
  v_expected_total numeric(14,2);
begin
  if new.contract_id is null then
    raise exception 'Το δελτίο πρέπει να συνδέεται με σύμβαση.';
  end if;

  select * into v_contract
  from public.mo_contracts c
  where c.id = new.contract_id;

  if not found then
    raise exception 'Δεν βρέθηκε η σύμβαση του δελτίου.';
  end if;

  if coalesce(v_contract.active, true) is not true then
    raise exception 'Δεν επιτρέπεται δελτίο σε ανενεργή σύμβαση.';
  end if;

  if v_contract.vat_rate is null then
    raise exception 'Η σύμβαση δεν έχει έγκυρο συντελεστή ΦΠΑ.';
  end if;

  if new.vat_rate is distinct from v_contract.vat_rate then
    raise exception using
      errcode = '22003',
      message = format(
        'Ο ΦΠΑ του δελτίου (%s%%) δεν συμφωνεί με τον ΦΠΑ της σύμβασης (%s%%).',
        new.vat_rate, v_contract.vat_rate
      );
  end if;

  v_expected_vat := round(coalesce(new.subtotal, 0) * v_contract.vat_rate / 100, 2);
  v_expected_total := round(coalesce(new.subtotal, 0) + v_expected_vat, 2);

  if new.vat is distinct from v_expected_vat
     or new.total is distinct from v_expected_total then
    raise exception 'Ασυμφωνία οικονομικών συνόλων δελτίου με τον ΦΠΑ της σύμβασης.';
  end if;

  if new.status in ('issued', 'sent', 'received') then
    if new.order_date is null then
      raise exception 'Εκδοθέν δελτίο απαιτεί ημερομηνία.';
    end if;
    if v_contract.start_date is not null and new.order_date < v_contract.start_date then
      raise exception using
        errcode = '22008',
        message = format(
          'Η ημερομηνία δελτίου %s προηγείται της έναρξης της σύμβασης %s.',
          new.order_date, v_contract.start_date
        );
    end if;
    if v_contract.end_date is not null and new.order_date > v_contract.end_date then
      raise exception using
        errcode = '22008',
        message = format(
          'Η ημερομηνία δελτίου %s είναι μεταγενέστερη της λήξης της σύμβασης %s.',
          new.order_date, v_contract.end_date
        );
    end if;
  end if;

  return new;
end;
$$;

revoke all on function public.app_order_contract_integrity_guard()
  from public, anon, authenticated;

drop trigger if exists trg_mo_orders_contract_integrity on public.mo_orders;
create trigger trg_mo_orders_contract_integrity
  before insert or update of contract_id, order_date, vat_rate, subtotal, vat, total, status
  on public.mo_orders
  for each row execute function public.app_order_contract_integrity_guard();

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
