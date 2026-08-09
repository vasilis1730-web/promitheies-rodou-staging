-- ============================================================================
-- v36.6.4 PRE-FLIGHT — δεν αλλάζει δεδομένα.
-- Αποτρέπει την εγκατάσταση των νέων invariants πάνω σε ήδη ασυνεπή ιστορικά.
-- ============================================================================

begin;

do $$
declare
  v_count bigint;
begin
  select count(*) into v_count
  from public.locked_studies s
  join public.mo_contracts c on c.source_study_id = s.id
  where s.record_status = 'cancelled';
  if v_count > 0 then
    raise exception 'v36.6.4 preflight: βρέθηκαν % σύμβαση/εις συνδεδεμένες με ακυρωμένη κλειδωμένη μελέτη.', v_count;
  end if;

  select count(*) into v_count
  from public.mo_orders o
  join public.mo_contracts c on c.id = o.contract_id
  where o.status in ('issued','sent','received')
    and o.vat_rate is distinct from c.vat_rate;
  if v_count > 0 then
    raise exception 'v36.6.4 preflight: βρέθηκαν % ενεργά/ιστορικά δελτία με ΦΠΑ διαφορετικό από τη σύμβαση.', v_count;
  end if;

  select count(*) into v_count
  from public.mo_orders o
  join public.mo_contracts c on c.id = o.contract_id
  where o.status in ('issued','sent','received')
    and (
      o.vat is distinct from round(coalesce(o.subtotal,0) * c.vat_rate / 100, 2)
      or o.total is distinct from round(coalesce(o.subtotal,0) + round(coalesce(o.subtotal,0) * c.vat_rate / 100, 2), 2)
    );
  if v_count > 0 then
    raise exception 'v36.6.4 preflight: βρέθηκαν % δελτία με οικονομικά σύνολα ασύμβατα με τη σύμβαση.', v_count;
  end if;

  select count(*) into v_count
  from public.mo_orders o
  join public.mo_contracts c on c.id = o.contract_id
  where o.status in ('issued','sent','received')
    and (
      o.order_date is null
      or (c.start_date is not null and o.order_date < c.start_date)
      or (c.end_date is not null and o.order_date > c.end_date)
    );
  if v_count > 0 then
    raise exception 'v36.6.4 preflight: βρέθηκαν % δελτία εκτός χρονικής διάρκειας σύμβασης.', v_count;
  end if;

  select count(*) into v_count
  from public.mo_orders o
  join public.mo_contracts c on c.id = o.contract_id
  where o.status in ('issued','sent','received')
    and o.supplier_id is distinct from c.supplier_id;
  if v_count > 0 then
    raise exception 'v36.6.4 preflight: βρέθηκαν % δελτία με προμηθευτή/ανάδοχο διαφορετικό από τη σύμβαση.', v_count;
  end if;

  select count(*) into v_count
  from public.mo_orders o
  join public.mo_contracts c on c.id = o.contract_id
  where o.status in ('issued','sent')
    and coalesce(c.active,true) is not true;
  if v_count > 0 then
    raise exception 'v36.6.4 preflight: βρέθηκαν % ανοικτά δελτία σε ανενεργή σύμβαση.', v_count;
  end if;
end;
$$;

commit;
