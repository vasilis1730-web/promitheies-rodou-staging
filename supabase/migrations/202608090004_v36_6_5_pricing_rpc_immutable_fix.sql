-- ============================================================================
-- v36.6.5 — immutable-at-creation contract pricing fix
-- Οι πραγματικές κατακυρωμένες τιμές γράφονται κατά τη δημιουργία της
-- σύμβασης. Υφιστάμενο οικονομικό snapshot δεν ξαναγράφεται.
-- ============================================================================

begin;

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
  v_study public.locked_studies%rowtype;
  v_contract public.mo_contracts%rowtype;
  v_supplier_id public.mo_suppliers.id%type;
  v_contract_id public.mo_contracts.id%type;
  v_mode text := coalesce(nullif(lower(btrim(p_pricing_mode)),''),'study');
  v_discount numeric := coalesce(p_discount_pct,0);
  v_total numeric(14,2);
  v_items integer := 0;
  v_bad_count integer := 0;
  v_base jsonb;
begin
  select * into v_study
  from public.locked_studies s
  where s.id::text=p_study_id
  for update;
  if not found then raise exception 'Δεν βρέθηκε η κλειδωμένη μελέτη.'; end if;
  if v_study.record_status<>'active' then raise exception 'Δεν καταχωρίζεται ανάθεση σε ακυρωμένη μελέτη.'; end if;
  if not public.app_can_write_unit(v_study.municipal_unit_id::bigint) then
    raise exception using errcode='42501',message='Δεν έχετε δικαίωμα καταχώρισης ανάθεσης για τη συγκεκριμένη Δ.Ε.';
  end if;

  select s.id into v_supplier_id
  from public.mo_suppliers s
  where s.id::text=p_supplier_id and coalesce(s.active,true)
  limit 1;
  if v_supplier_id is null then raise exception 'Δεν βρέθηκε ενεργός προμηθευτής/ανάδοχος.'; end if;
  if p_start_date is not null and p_end_date is not null and p_end_date<p_start_date then
    raise exception 'Η ημερομηνία λήξης δεν μπορεί να προηγείται της έναρξης.';
  end if;
  if p_vat_rate is null or p_vat_rate<0 or p_vat_rate>100 then
    raise exception 'Μη έγκυρος συντελεστής ΦΠΑ.';
  end if;
  if v_mode not in ('study','discount','item_prices') then
    raise exception 'Ο τρόπος τιμολόγησης πρέπει να είναι study, discount ή item_prices.';
  end if;
  if v_mode='discount' and (v_discount<0 or v_discount>=100) then
    raise exception 'Η ενιαία έκπτωση πρέπει να είναι από 0%% έως μικρότερη του 100%%.';
  end if;

  -- Υφιστάμενη σύμβαση: το αρχικό οικονομικό snapshot δεν ξαναγράφεται.
  if nullif(p_contract_id,'') is not null then
    select * into v_contract
    from public.mo_contracts c
    where c.id::text=p_contract_id and c.source_study_id=v_study.id
    for update;
    if not found then raise exception 'Η ανάθεση δεν αντιστοιχεί στην επιλεγμένη μελέτη.'; end if;

    if v_mode is distinct from v_contract.pricing_mode
       or (v_mode='discount' and round(v_discount,4) is distinct from round(v_contract.discount_pct,4))
       or p_vat_rate is distinct from v_contract.vat_rate then
      raise exception using
        errcode='55000',
        message='Δεν αλλάζει η οικονομική τιμολόγηση ή ο ΦΠΑ υφιστάμενης σύμβασης. Οι κατακυρωμένες τιμές αποτελούν αμετάβλητο αρχικό snapshot.';
    end if;

    if v_mode='item_prices' and p_item_prices is not null then
      select count(*) into v_bad_count
      from public.mo_contract_items i
      where i.contract_id=v_contract.id
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
          and abs((x.value->>'unit_price')::numeric-i.unit_price)<=0.00005
        ) <> 1;
      if v_bad_count>0 then
        raise exception using errcode='55000',message='Δεν αλλάζουν οι κατακυρωμένες τιμές υφιστάμενης σύμβασης.';
      end if;
    end if;

    v_base:=public.save_contract_atomic(
      p_contract_id,p_study_id,p_supplier_id,p_title,p_adam,p_protocol_no,
      p_start_date,p_end_date,p_vat_rate
    );
    return v_base || jsonb_build_object(
      'estimated_amount',v_contract.estimated_amount,
      'contract_amount',v_contract.total_amount,
      'pricing_mode',v_contract.pricing_mode,
      'discount_pct',v_contract.discount_pct
    );
  end if;

  if exists(select 1 from public.mo_contracts c where c.source_study_id=v_study.id) then
    raise exception 'Υπάρχει ήδη ανάθεση για τη συγκεκριμένη κλειδωμένη μελέτη.';
  end if;

  if v_mode='item_prices' then
    if p_item_prices is null or jsonb_typeof(p_item_prices)<>'array' then
      raise exception 'Για πραγματικές τιμές ανά είδος απαιτείται πίνακας p_item_prices.';
    end if;
    if jsonb_array_length(p_item_prices)<>jsonb_array_length(coalesce(v_study.lines::jsonb,'[]'::jsonb)) then
      raise exception 'Πρέπει να δοθεί ακριβώς μία πραγματική τιμή για κάθε συμβατικό είδος.';
    end if;
    select count(*) into v_bad_count
    from jsonb_array_elements(coalesce(v_study.lines::jsonb,'[]'::jsonb)) l(value)
    where (
      select count(*)
      from jsonb_array_elements(p_item_prices) x(value)
      where nullif(x.value->>'material_id','')=nullif(l.value->>'material_id','')
        and coalesce(x.value->>'unit_price','') ~ '^[+]?[0-9]+([.][0-9]+)?$'
        and (x.value->>'unit_price')::numeric>=0
    )<>1;
    if v_bad_count>0 then
      raise exception 'Λείπει, διπλασιάζεται ή δεν είναι έγκυρη πραγματική τιμή σε % συμβατικό/ά είδος/η.',v_bad_count;
    end if;
  end if;

  select round(coalesce(sum(
    (l.value->>'quantity')::numeric *
    case
      when v_mode='study' then (l.value->>'unit_price')::numeric
      when v_mode='discount' then round((l.value->>'unit_price')::numeric*(100-v_discount)/100,4)
      else (
        select round((x.value->>'unit_price')::numeric,4)
        from jsonb_array_elements(p_item_prices) x(value)
        where x.value->>'material_id'=l.value->>'material_id'
        limit 1
      )
    end
  ),0),2)
  into v_total
  from jsonb_array_elements(coalesce(v_study.lines::jsonb,'[]'::jsonb)) l(value);

  if v_total>v_study.net_total+0.005 then
    raise exception using
      errcode='22003',
      message=format(
        'Η πραγματική οικονομική προσφορά %s € υπερβαίνει την εκτιμώμενη αξία της μελέτης %s €.',
        round(v_total,2),round(v_study.net_total,2)
      );
  end if;

  insert into public.mo_contracts(
    title,cpv,total_amount,estimated_amount,pricing_mode,discount_pct,vat_rate,active,
    municipal_unit_id,source_study_id,supplier_id,adam,protocol_no,start_date,end_date,
    updated_at,updated_by
  ) values(
    coalesce(nullif(btrim(p_title),''),'Ανάθεση κλειδωμένης μελέτης #'||v_study.seq),
    null,v_total,v_study.net_total,v_mode,
    case when v_mode='discount' then round(v_discount,4) else 0 end,
    p_vat_rate,true,v_study.municipal_unit_id,v_study.id,v_supplier_id,
    nullif(btrim(coalesce(p_adam,'')),''),nullif(btrim(coalesce(p_protocol_no,'')),''),
    p_start_date,p_end_date,now(),auth.uid()
  ) returning * into v_contract;
  v_contract_id:=v_contract.id;

  insert into public.mo_contract_items(
    contract_id,code,description,unit,cpv,contract_qty,
    estimated_unit_price,unit_price,material_id
  )
  select
    v_contract_id,
    coalesce(nullif(l.value->>'code',''),(row_number() over())::text),
    coalesce(nullif(l.value->>'name',''),nullif(l.value->>'short_name',''),'—'),
    coalesce(l.value->>'unit',''),nullif(l.value->>'cpv',''),
    (l.value->>'quantity')::numeric,
    (l.value->>'unit_price')::numeric,
    case
      when v_mode='study' then (l.value->>'unit_price')::numeric
      when v_mode='discount' then round((l.value->>'unit_price')::numeric*(100-v_discount)/100,4)
      else (
        select round((x.value->>'unit_price')::numeric,4)
        from jsonb_array_elements(p_item_prices) x(value)
        where x.value->>'material_id'=l.value->>'material_id'
        limit 1
      )
    end,
    m.id
  from jsonb_array_elements(coalesce(v_study.lines::jsonb,'[]'::jsonb)) l(value)
  left join public.materials m on m.id::text=l.value->>'material_id';
  get diagnostics v_items=row_count;

  perform public.app_write_audit(
    'contract_created','mo_contracts',v_contract_id::text,v_study.municipal_unit_id::bigint,
    null,null,to_jsonb(v_contract),
    jsonb_build_object(
      'study_id',v_study.id::text,'contract_items',v_items,
      'estimated_amount',v_study.net_total,'contract_amount',v_total,
      'pricing_mode',v_mode,'discount_pct',case when v_mode='discount' then round(v_discount,4) else 0 end
    )
  );

  return jsonb_build_object(
    'contract_id',v_contract_id::text,'study_id',v_study.id::text,
    'items',v_items,'created',true,
    'estimated_amount',v_study.net_total,'contract_amount',v_total,
    'pricing_mode',v_mode,'discount_pct',case when v_mode='discount' then round(v_discount,4) else 0 end
  );
end;
$$;

revoke all on function public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)
  from public,anon;
grant execute on function public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)
  to authenticated;

commit;
