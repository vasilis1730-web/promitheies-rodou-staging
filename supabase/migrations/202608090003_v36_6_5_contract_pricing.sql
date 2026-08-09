-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — v36.6.5 CONTRACT PRICING & FINANCIAL CONSISTENCY
--
-- 1. Διαχωρίζει εκτιμώμενη αξία μελέτης από πραγματική συμβατική αξία.
-- 2. Υποστηρίζει: τιμές μελέτης, ενιαία έκπτωση %, πραγματικές τιμές ανά είδος.
-- 3. Τα δελτία δεσμεύουν το πραγματικό συμβατικό ποσό, όχι τον προϋπολογισμό.
-- 4. Η «χρέωση ως» σε εκδοθέν δελτίο απαιτεί ακριβή οικονομική ισοδυναμία.
-- 5. Επιτρέπει admin-only διόρθωση ΜΟΝΟ αριθμού/ημερομηνίας/ΑΔΑ απόφασης,
--    χωρίς μεταβολή των ήδη χρησιμοποιημένων τεσσάρων ομάδων Δ.Ε.
-- 6. Δηλώνει schema 36.6.5 μόνο στο τέλος.
-- ============================================================================

begin;

alter table public.mo_contracts
  add column if not exists estimated_amount numeric(14,2),
  add column if not exists pricing_mode text,
  add column if not exists discount_pct numeric(7,4);

alter table public.mo_contract_items
  add column if not exists estimated_unit_price numeric(14,4);

update public.mo_contracts c
set estimated_amount = coalesce(c.estimated_amount, s.net_total, c.total_amount),
    pricing_mode = coalesce(nullif(c.pricing_mode,''), 'study'),
    discount_pct = coalesce(c.discount_pct, 0)
from public.locked_studies s
where c.source_study_id = s.id
  and (c.estimated_amount is null or c.pricing_mode is null or c.discount_pct is null);

update public.mo_contracts
set estimated_amount = coalesce(estimated_amount,total_amount,0),
    pricing_mode = coalesce(nullif(pricing_mode,''),'study'),
    discount_pct = coalesce(discount_pct,0)
where estimated_amount is null or pricing_mode is null or discount_pct is null;

update public.mo_contract_items
set estimated_unit_price = coalesce(estimated_unit_price,unit_price,0)
where estimated_unit_price is null;

alter table public.mo_contracts
  alter column estimated_amount set default 0,
  alter column estimated_amount set not null,
  alter column pricing_mode set default 'study',
  alter column pricing_mode set not null,
  alter column discount_pct set default 0,
  alter column discount_pct set not null;

alter table public.mo_contract_items
  alter column estimated_unit_price set default 0,
  alter column estimated_unit_price set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.mo_contracts'::regclass
      and conname='mo_contracts_pricing_mode_check'
  ) then
    alter table public.mo_contracts
      add constraint mo_contracts_pricing_mode_check
      check (pricing_mode in ('study','discount','item_prices')) not valid;
    alter table public.mo_contracts validate constraint mo_contracts_pricing_mode_check;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.mo_contracts'::regclass
      and conname='mo_contracts_discount_pct_check'
  ) then
    alter table public.mo_contracts
      add constraint mo_contracts_discount_pct_check
      check (discount_pct >= 0 and discount_pct < 100) not valid;
    alter table public.mo_contracts validate constraint mo_contracts_discount_pct_check;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid='public.mo_contracts'::regclass
      and conname='mo_contracts_amount_not_above_estimate'
  ) then
    alter table public.mo_contracts
      add constraint mo_contracts_amount_not_above_estimate
      check (total_amount <= estimated_amount + 0.005) not valid;
    alter table public.mo_contracts validate constraint mo_contracts_amount_not_above_estimate;
  end if;
end;
$$;

create or replace function public.app_contract_pricing_header_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.estimated_amount is null then
    new.estimated_amount := coalesce(new.total_amount,0);
  end if;
  new.pricing_mode := coalesce(nullif(lower(btrim(new.pricing_mode)),''),'study');
  new.discount_pct := coalesce(new.discount_pct,0);

  if new.estimated_amount < 0 or new.total_amount < 0 then
    raise exception 'Η εκτιμώμενη και η συμβατική καθαρή αξία δεν μπορεί να είναι αρνητική.';
  end if;
  if new.pricing_mode not in ('study','discount','item_prices') then
    raise exception 'Μη έγκυρος τρόπος συμβατικής τιμολόγησης.';
  end if;
  if new.discount_pct < 0 or new.discount_pct >= 100 then
    raise exception 'Η έκπτωση πρέπει να είναι από 0%% έως μικρότερη του 100%%.';
  end if;
  if new.total_amount > new.estimated_amount + 0.005 then
    raise exception using
      errcode='22003',
      message=format(
        'Η πραγματική συμβατική αξία %s € δεν μπορεί να υπερβαίνει την εκτιμώμενη αξία της μελέτης %s €.',
        round(new.total_amount,2),round(new.estimated_amount,2)
      );
  end if;

  if tg_op='UPDATE'
     and (
       new.total_amount is distinct from old.total_amount
       or new.estimated_amount is distinct from old.estimated_amount
       or new.pricing_mode is distinct from old.pricing_mode
       or new.discount_pct is distinct from old.discount_pct
     )
     and exists (
       select 1 from public.mo_orders o
       where o.contract_id=old.id and o.status in ('issued','sent','received')
     ) then
    raise exception using
      errcode='55000',
      message='Δεν αλλάζει η οικονομική τιμολόγηση σύμβασης που έχει ήδη εκδοθέντα δελτία.';
  end if;
  return new;
end;
$$;

revoke all on function public.app_contract_pricing_header_guard() from public,anon,authenticated;

drop trigger if exists trg_mo_contracts_pricing_header_guard on public.mo_contracts;
create trigger trg_mo_contracts_pricing_header_guard
  before insert or update of total_amount,estimated_amount,pricing_mode,discount_pct
  on public.mo_contracts
  for each row execute function public.app_contract_pricing_header_guard();

create or replace function public.app_contract_item_pricing_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if new.estimated_unit_price is null then
    new.estimated_unit_price := coalesce(new.unit_price,0);
  end if;
  if coalesce(new.estimated_unit_price,0) < 0 or coalesce(new.unit_price,0) < 0 then
    raise exception 'Οι τιμές μονάδας σύμβασης δεν μπορεί να είναι αρνητικές.';
  end if;

  if tg_op='UPDATE'
     and (
       new.unit_price is distinct from old.unit_price
       or new.estimated_unit_price is distinct from old.estimated_unit_price
     )
     and exists (
       select 1
       from public.mo_orders o
       left join public.mo_order_items oi on oi.order_id=o.id
       where o.contract_id=old.contract_id
         and o.status in ('issued','sent','received')
         and (
           oi.contract_item_id=old.id
           or exists (
             select 1
             from jsonb_array_elements(coalesce(oi.mapping::jsonb,'[]'::jsonb)) mp(value)
             where mp.value->>'contract_item_id'=old.id::text
           )
         )
     ) then
    raise exception using
      errcode='55000',
      message='Δεν αλλάζει η συμβατική τιμή είδους που έχει ήδη χρησιμοποιηθεί σε εκδοθέν δελτίο.';
  end if;
  return new;
end;
$$;

revoke all on function public.app_contract_item_pricing_guard() from public,anon,authenticated;

drop trigger if exists trg_mo_contract_items_pricing_guard on public.mo_contract_items;
create trigger trg_mo_contract_items_pricing_guard
  before insert or update of unit_price,estimated_unit_price
  on public.mo_contract_items
  for each row execute function public.app_contract_item_pricing_guard();

create or replace function public.save_contract_pricing_atomic(
  p_contract_id text,
  p_study_id text,
  p_supplier_id text,
  p_title text,
  p_adam text,
  p_protocol_no text,
  p_start_date date,
  p_end_date date,
  p_vat_rate numeric,
  p_pricing_mode text,
  p_discount_pct numeric,
  p_item_prices jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_base jsonb;
  v_contract_id public.mo_contracts.id%type;
  v_contract public.mo_contracts%rowtype;
  v_study public.locked_studies%rowtype;
  v_mode text := coalesce(nullif(lower(btrim(p_pricing_mode)),''),'study');
  v_discount numeric := coalesce(p_discount_pct,0);
  v_total numeric(14,2);
  v_item_count integer;
  v_price_count integer;
  v_bad_count integer;
begin
  if v_mode not in ('study','discount','item_prices') then
    raise exception 'Ο τρόπος τιμολόγησης πρέπει να είναι study, discount ή item_prices.';
  end if;
  if v_mode='discount' and (v_discount < 0 or v_discount >= 100) then
    raise exception 'Η ενιαία έκπτωση πρέπει να είναι από 0%% έως μικρότερη του 100%%.';
  end if;

  v_base := public.save_contract_atomic(
    p_contract_id,p_study_id,p_supplier_id,p_title,p_adam,p_protocol_no,
    p_start_date,p_end_date,p_vat_rate
  );
  v_contract_id := (v_base->>'contract_id')::public.mo_contracts.id%type;

  select * into v_study
  from public.locked_studies s
  where s.id::text=p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;

  select * into v_contract
  from public.mo_contracts c
  where c.id=v_contract_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η σύμβαση μετά την αποθήκευση.'; end if;

  update public.mo_contract_items i
  set estimated_unit_price=coalesce(i.estimated_unit_price,i.unit_price,0)
  where i.contract_id=v_contract_id;

  if v_mode='study' then
    update public.mo_contract_items i
    set unit_price=i.estimated_unit_price
    where i.contract_id=v_contract_id;
    v_discount := 0;

  elsif v_mode='discount' then
    update public.mo_contract_items i
    set unit_price=round(i.estimated_unit_price*(100-v_discount)/100,4)
    where i.contract_id=v_contract_id;

  else
    if p_item_prices is null or jsonb_typeof(p_item_prices)<>'array' then
      raise exception 'Για πραγματικές τιμές ανά είδος απαιτείται πίνακας p_item_prices.';
    end if;

    select count(*) into v_item_count
    from public.mo_contract_items i where i.contract_id=v_contract_id;
    select jsonb_array_length(p_item_prices) into v_price_count;
    if v_price_count<>v_item_count then
      raise exception 'Πρέπει να δοθεί ακριβώς μία πραγματική τιμή για κάθε συμβατικό είδος.';
    end if;

    select count(*) into v_bad_count
    from public.mo_contract_items i
    where i.contract_id=v_contract_id
      and (
        select count(*)
        from jsonb_array_elements(p_item_prices) x(value)
        where (
          nullif(x.value->>'contract_item_id','')=i.id::text
          or (
            nullif(x.value->>'contract_item_id','') is null
            and i.material_id is not null
            and nullif(x.value->>'material_id','')=i.material_id::text
          )
        )
        and coalesce(x.value->>'unit_price','') ~ '^[+]?[0-9]+([.][0-9]+)?$'
        and (x.value->>'unit_price')::numeric >= 0
      ) <> 1;
    if v_bad_count>0 then
      raise exception 'Λείπει, διπλασιάζεται ή δεν είναι έγκυρη πραγματική τιμή σε % συμβατικό/ά είδος/η.',v_bad_count;
    end if;

    update public.mo_contract_items i
    set unit_price=(
      select round((x.value->>'unit_price')::numeric,4)
      from jsonb_array_elements(p_item_prices) x(value)
      where (
        nullif(x.value->>'contract_item_id','')=i.id::text
        or (
          nullif(x.value->>'contract_item_id','') is null
          and i.material_id is not null
          and nullif(x.value->>'material_id','')=i.material_id::text
        )
      )
      limit 1
    )
    where i.contract_id=v_contract_id;
    v_discount := 0;
  end if;

  select round(coalesce(sum(coalesce(i.contract_qty,0)*coalesce(i.unit_price,0)),0),2)
  into v_total
  from public.mo_contract_items i
  where i.contract_id=v_contract_id;

  if v_total > v_study.net_total + 0.005 then
    raise exception using
      errcode='22003',
      message=format(
        'Η πραγματική οικονομική προσφορά %s € υπερβαίνει την εκτιμώμενη αξία της μελέτης %s €.',
        round(v_total,2),round(v_study.net_total,2)
      );
  end if;

  update public.mo_contracts c
  set estimated_amount=v_study.net_total,
      total_amount=v_total,
      pricing_mode=v_mode,
      discount_pct=case when v_mode='discount' then round(v_discount,4) else 0 end,
      updated_at=now(),
      updated_by=auth.uid()
  where c.id=v_contract_id
  returning * into v_contract;

  perform public.app_write_audit(
    'contract_pricing_set','mo_contracts',v_contract_id::text,
    v_study.municipal_unit_id::bigint,null,null,
    jsonb_build_object(
      'estimated_amount',v_contract.estimated_amount,
      'contract_amount',v_contract.total_amount,
      'pricing_mode',v_contract.pricing_mode,
      'discount_pct',v_contract.discount_pct
    ),
    jsonb_build_object('study_id',v_study.id::text)
  );

  return v_base || jsonb_build_object(
    'estimated_amount',v_contract.estimated_amount,
    'contract_amount',v_contract.total_amount,
    'pricing_mode',v_contract.pricing_mode,
    'discount_pct',v_contract.discount_pct
  );
end;
$$;

revoke all on function public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)
  from public,anon;
grant execute on function public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)
  to authenticated;

create or replace function public.app_order_contract_financial_guard()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_contract_total numeric(14,2);
  v_existing numeric(14,2);
  v_bad_custom integer;
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

  select count(*) into v_bad_custom
  from public.mo_order_items oi
  where oi.order_id=new.id
    and oi.is_custom is true
    and abs(
      round(coalesce((
        select sum((mp.value->>'qty')::numeric * ci.unit_price)
        from jsonb_array_elements(coalesce(oi.mapping::jsonb,'[]'::jsonb)) mp(value)
        join public.mo_contract_items ci
          on ci.id::text=mp.value->>'contract_item_id'
         and ci.contract_id=new.contract_id
        where coalesce(mp.value->>'qty','') ~ '^[+]?[0-9]+([.][0-9]+)?$'
      ),0),2)
      - coalesce(oi.line_total,0)
    ) > 0.005;

  if v_bad_custom>0 then
    raise exception using
      errcode='22003',
      message='Η «χρέωση ως» σε εκδοθέν δελτίο πρέπει να έχει ακριβώς ίση συμβατική αξία με την ελεύθερη γραμμή.';
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

create or replace function public.amend_award_group_decision_metadata(
  p_budget_year integer,
  p_decision_number text,
  p_decision_date date,
  p_decision_ada text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
set row_security = off
as $$
declare
  v_before public.award_group_configurations%rowtype;
  v_after public.award_group_configurations%rowtype;
  v_ada text := upper(btrim(coalesce(p_decision_ada,'')));
begin
  if not public.app_is_admin() then
    raise exception using errcode='42501',message='Μόνο διαχειριστής μπορεί να διορθώσει τα στοιχεία της απόφασης Δ.Σ.';
  end if;
  if nullif(btrim(coalesce(p_decision_number,'')),'') is null
     or p_decision_date is null
     or nullif(v_ada,'') is null then
    raise exception 'Απαιτούνται αριθμός απόφασης, ημερομηνία και ΑΔΑ.';
  end if;
  if p_decision_date>current_date then
    raise exception 'Η ημερομηνία απόφασης δεν μπορεί να είναι μελλοντική.';
  end if;
  if v_ada !~ '^[0-9A-ZΑ-Ω]+-[0-9A-ZΑ-Ω]+$' then
    raise exception 'Ο ΑΔΑ δεν έχει έγκυρη μορφή (αναμένεται μορφή ΧΧΧΧ-ΧΧΧ).';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Η διορθωτική μεταβολή απαιτεί αιτιολογία.';
  end if;

  select * into v_before
  from public.award_group_configurations c
  where c.budget_year=p_budget_year and c.is_active
  for update;
  if not found then raise exception 'Δεν βρέθηκε ενεργή απόφαση για το έτος %.',p_budget_year; end if;

  if not public.app_award_group_configuration_is_canonical(p_budget_year) then
    raise exception 'Η ενεργή κατανομή δεν είναι η κανονική τετραμερής κατανομή του Δήμου Ρόδου.';
  end if;

  update public.award_group_configurations c
  set decision_number=btrim(p_decision_number),
      decision_date=p_decision_date,
      decision_ada=v_ada,
      updated_at=now(),
      updated_by=auth.uid()
  where c.id=v_before.id
  returning * into v_after;

  perform public.app_write_audit(
    'award_group_decision_metadata_amended','award_group_configurations',v_before.id::text,
    null,p_reason,
    jsonb_build_object('decision_number',v_before.decision_number,'decision_date',v_before.decision_date,'decision_ada',v_before.decision_ada),
    jsonb_build_object('decision_number',v_after.decision_number,'decision_date',v_after.decision_date,'decision_ada',v_after.decision_ada),
    jsonb_build_object('budget_year',p_budget_year,'groups_unchanged',true)
  );

  return jsonb_build_object(
    'configuration_id',v_after.id,
    'budget_year',v_after.budget_year,
    'decision_number',v_after.decision_number,
    'decision_date',v_after.decision_date,
    'decision_ada',v_after.decision_ada,
    'groups_unchanged',true
  );
end;
$$;

revoke all on function public.amend_award_group_decision_metadata(integer,text,date,text,text)
  from public,anon;
grant execute on function public.amend_award_group_decision_metadata(integer,text,date,text,text)
  to authenticated;

create or replace function public.app_schema_version()
returns text
language sql
stable
set search_path = public, pg_temp
as $$
  select '36.6.5'::text
$$;

revoke all on function public.app_schema_version() from public,anon;
grant execute on function public.app_schema_version() to authenticated;

commit;
