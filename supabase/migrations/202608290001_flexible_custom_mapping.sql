-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΕΥΕΛΙΚΤΗ ΑΝΤΙΣΤΟΙΧΙΣΗ ΕΛΕΥΘΕΡΩΝ ΓΡΑΜΜΩΝ («χρέωση ως»)
--
-- ΠΡΟΒΛΗΜΑ
-- Η γραμμή «εκτός τιμολογίου» απαιτούσε αντιστοίχιση με ΑΚΡΙΒΩΣ ίση συμβατική
-- αξία (±0,005 €). Στην πράξη αυτό είναι συχνά αδύνατο: τα συμβατικά είδη
-- έχουν βήμα ποσότητας (π.χ. ακέραια τεμάχια), οπότε καμία ποσότητα δεν δίνει
-- ακριβώς την αξία της ελεύθερης γραμμής. Το δελτίο έμενε αδύνατο να εκδοθεί.
--
-- ΛΥΣΗ
-- Η αντιστοίχιση κρατά τον ρόλο της τεκμηρίωσης: δηλώνει ΣΕ ΠΟΙΑ είδη της
-- σύμβασης χρεώνεται η ελεύθερη γραμμή και πόση συμβατική ΠΟΣΟΤΗΤΑ αναλώνει.
-- Παύει να απαιτείται ταύτιση αξίας.
--
-- ΓΙΑΤΙ ΕΙΝΑΙ ΟΙΚΟΝΟΜΙΚΑ ΑΣΦΑΛΕΣ
-- Το χρήμα ΔΕΝ αφαιρείται ποτέ από τη σύμβαση μέσω της αντιστοίχισης. Τα
-- δεσμευμένα ποσά (committed_net) προκύπτουν αποκλειστικά από το subtotal των
-- δελτίων, δηλαδή από την πραγματική αξία των γραμμών (ποσότητα × τιμή). Η
-- αντιστοίχιση τροφοδοτεί μόνο τον απολογισμό ΠΟΣΟΤΗΤΩΝ ανά συμβατικό είδος.
-- Επομένως:
--   * το οικονομικό πλαφόν της σύμβασης παραμένει απαράβατο (guard subtotal),
--   * το πλαφόν συμβατικής ποσότητας ανά είδος παραμένει απαράβατο
--     (contract_qty στη save_order_atomic, μετρά και τις αντιστοιχίσεις),
--   * κάθε ελεύθερη γραμμή εξακολουθεί να απαιτεί τουλάχιστον μία αντιστοίχιση,
--     ώστε να μην υπάρχει χρέωση χωρίς συμβατικό έρεισμα.
--
-- Αλλάζουν δύο σημεία ελέγχου:
--   1. public.save_order_atomic  — «πλήρης κάλυψη» → «τουλάχιστον μία αντιστοίχιση»
--   2. public.app_order_contract_financial_guard — καταργείται ο έλεγχος
--      ακριβούς ισοδυναμίας· διατηρείται ο έλεγχος συμβατικού υπολοίπου και
--      προστίθεται έλεγχος ύπαρξης αντιστοίχισης.
--
-- Η δηλωμένη έκδοση schema παραμένει 36.6.6: η αλλαγή είναι συμβατή προς τα
-- πίσω (χαλαρώνει έλεγχο, δεν αλλάζει δομή), ώστε ο ήδη δημοσιευμένος client
-- να συνεχίσει να λειτουργεί όσο δεν έχει προλάβει να ανανεωθεί.
--
-- Τα δικαιώματα εκτέλεσης δεν θίγονται: το create or replace διατηρεί το
-- υπάρχον ACL (η save_order_atomic καλείται μόνο μέσω του resilient wrapper).
-- ============================================================================

begin;

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

      -- Ευέλικτη αντιστοίχιση: η αντιστοίχιση («χρέωση ως») δηλώνει ΣΕ ΠΟΙΑ είδη της σύμβασης
      -- χρεώνεται η ελεύθερη γραμμή. Δεν απαιτείται πλέον ταύτιση αξίας: οι
      -- συμβατικές ποσότητες σπάνια αναλύονται σε ακριβώς ίσο ποσό (ακέραια
      -- τεμάχια, βήμα ποσότητας). Το ΧΡΗΜΑ αφαιρείται από τη σύμβαση με την
      -- πραγματική αξία της γραμμής (line_total → subtotal), οπότε το
      -- οικονομικό υπόλοιπο παραμένει ακριβές ανεξάρτητα από την αντιστοίχιση.
      if coalesce(p_issue, false) and v_line_total > 0.005 and jsonb_array_length(v_normalized_map) = 0 then
        raise exception 'Η ελεύθερη γραμμή «%» χρειάζεται τουλάχιστον μία αντιστοίχιση με είδος της σύμβασης.', v_item ->> 'description';
      end if;
      v_covered := round(v_covered, 2);

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

comment on function public.save_order_atomic(text,text,date,text,text,text,numeric,jsonb,boolean) is
  'Ευέλικτη αντιστοίχιση: η ελεύθερη γραμμή απαιτεί τουλάχιστον μία αντιστοίχιση με συμβατικό είδος, χωρίς απαίτηση ίσης αξίας. Το χρήμα δεσμεύεται από την πραγματική αξία της γραμμής, οι συμβατικές ποσότητες από την αντιστοίχιση.';

-- ---------------------------------------------------------------------------
-- Οικονομικός φύλακας δελτίου: το πλαφόν της σύμβασης παραμένει απαράβατο.
-- Η ισοδυναμία αξίας στη «χρέωση ως» καταργείται· στη θέση της μπαίνει
-- δομικός έλεγχος: εκδοθείσα ελεύθερη γραμμή χωρίς καμία αντιστοίχιση
-- εξακολουθεί να απορρίπτεται.
-- ---------------------------------------------------------------------------
create or replace function public.app_order_contract_financial_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_contract_total numeric(14,2);
  v_existing numeric(14,2);
  v_unmapped integer;
begin
  if new.status not in ('issued','sent','received') then
    return new;
  end if;

  select c.total_amount into v_contract_total
  from public.mo_contracts c
  where c.id=new.contract_id;
  if v_contract_total is null then
    raise exception 'Δεν βρέθηκε συμβατική καθαρή αξία για τον οικονομικό έλεγχο δελτίου.';
  end if;

  select round(coalesce(sum(o.subtotal),0),2)
  into v_existing
  from public.mo_orders o
  where o.contract_id=new.contract_id
    and o.status in ('issued','sent','received')
    and o.id<>new.id;

  if v_existing + coalesce(new.subtotal,0) > v_contract_total + 0.005 then
    raise exception using
      errcode='22003',
      message=format(
        'Το δελτίο υπερβαίνει το πραγματικό συμβατικό υπόλοιπο: δεσμευμένα %s €, νέο %s €, σύμβαση %s €.',
        round(v_existing,2),round(coalesce(new.subtotal,0),2),round(v_contract_total,2)
      );
  end if;

  -- Μόνο γραμμή με πραγματική αξία χρειάζεται έρεισμα· γραμμή μηδενικής αξίας
  -- ήταν και παλαιότερα αποδεκτή χωρίς αντιστοίχιση και δεν αναδρομικοποιείται.
  select count(*) into v_unmapped
  from public.mo_order_items oi
  where oi.order_id=new.id
    and oi.is_custom is true
    and coalesce(oi.line_total,0)>0.005
    and coalesce(jsonb_array_length(
      case when jsonb_typeof(coalesce(oi.mapping::jsonb,'[]'::jsonb))='array'
        then coalesce(oi.mapping::jsonb,'[]'::jsonb) else '[]'::jsonb end
    ),0)=0;

  if v_unmapped>0 then
    raise exception using
      errcode='22003',
      message='Κάθε γραμμή εκτός τιμολογίου σε εκδοθέν δελτίο χρειάζεται τουλάχιστον μία αντιστοίχιση με είδος της σύμβασης («χρέωση ως»).';
  end if;
  return new;
end;
$$;

revoke all on function public.app_order_contract_financial_guard() from public,anon,authenticated;

drop trigger if exists trg_mo_orders_contract_financial_guard on public.mo_orders;
create trigger trg_mo_orders_contract_financial_guard
  before insert or update of contract_id,subtotal,status
  on public.mo_orders
  for each row execute function public.app_order_contract_financial_guard();

comment on column public.mo_order_items.mapping is
  '«χρέωση ως» — σε ποια συμβατικά είδη και με πόση ισοδύναμη ποσότητα χρεώνεται μια γραμμή εκτός τιμολογίου. Αναλώνει συμβατικές ΠΟΣΟΤΗΤΕΣ· η δέσμευση ΧΡΗΜΑΤΟΣ γίνεται από την πραγματική αξία της γραμμής. Δεν απαιτείται ίση αξία.';

commit;
