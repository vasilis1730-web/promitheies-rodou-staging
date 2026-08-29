-- ==========================================================================
-- 110_VERIFY_V36_6_5.sql — READ ONLY
-- Φάση 3: πραγματικές συμβατικές τιμές, συμβατικό υπόλοιπο, «χρέωση ως»
-- και διοικητικά μεταδεδομένα της απόφασης ομάδων Δ.Ε.
-- Δεν εκτελεί DDL/DML.
-- ==========================================================================

with
schema_objects as (
  select
    public.app_schema_version() as schema_version,
    to_regprocedure('public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)') is not null
      as pricing_rpc_exists,
    to_regprocedure('public.amend_award_group_decision_metadata(integer,text,date,text,text)') is not null
      as decision_metadata_rpc_exists,
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='mo_contracts' and column_name='estimated_amount')
      as contract_estimated_amount_exists,
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='mo_contracts' and column_name='pricing_mode')
      as contract_pricing_mode_exists,
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='mo_contracts' and column_name='discount_pct')
      as contract_discount_pct_exists,
    exists(select 1 from information_schema.columns where table_schema='public' and table_name='mo_contract_items' and column_name='estimated_unit_price')
      as item_estimated_unit_price_exists
),
trigger_checks as (
  select
    exists(
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='mo_contracts'
        and t.tgname='trg_mo_contracts_pricing_header_guard' and not t.tgisinternal and t.tgenabled<>'D'
    ) as contract_pricing_header_guard,
    exists(
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='mo_contract_items'
        and t.tgname='trg_mo_contract_items_pricing_guard' and not t.tgisinternal and t.tgenabled<>'D'
    ) as contract_item_pricing_guard,
    exists(
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='mo_orders'
        and t.tgname='trg_mo_orders_contract_financial_guard' and not t.tgisinternal and t.tgenabled<>'D'
    ) as order_contract_financial_guard,
    exists(
      select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname='mo_contract_items'
        and t.tgname='trg_mo_contract_items_immutable' and not t.tgisinternal and t.tgenabled<>'D'
    ) as original_contract_items_immutable_guard_preserved
),
function_checks as (
  select
    coalesce(position('estimated_amount' in lower(pg_get_functiondef(
      to_regprocedure('public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)')
    )))>0,false) as pricing_rpc_tracks_estimated_amount,
    coalesce(position('item_prices' in lower(pg_get_functiondef(
      to_regprocedure('public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)')
    )))>0,false) as pricing_rpc_supports_item_prices,
    coalesce(position('discount' in lower(pg_get_functiondef(
      to_regprocedure('public.save_contract_pricing_atomic(text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb)')
    )))>0,false) as pricing_rpc_supports_discount,
    coalesce(position('app_is_admin' in lower(pg_get_functiondef(
      to_regprocedure('public.amend_award_group_decision_metadata(integer,text,date,text,text)')
    )))>0,false) as decision_metadata_rpc_is_admin_guarded
),
contract_item_totals as (
  select
    c.id as contract_id,
    round(coalesce(sum(coalesce(i.contract_qty,0)*coalesce(i.unit_price,0)),0),2) as item_total
  from public.mo_contracts c
  left join public.mo_contract_items i on i.contract_id=c.id
  group by c.id
),
contract_violations as (
  select
    count(*)::int as contracts_total,
    count(*) filter(where c.total_amount>c.estimated_amount+0.005)::int as contract_above_estimate,
    count(*) filter(where abs(c.total_amount-coalesce(t.item_total,0))>0.005)::int as contract_total_vs_items_mismatch,
    count(*) filter(where s.id is not null and abs(c.estimated_amount-s.net_total)>0.005)::int as contract_estimate_vs_locked_study_mismatch,
    count(*) filter(where c.pricing_mode not in ('study','discount','item_prices'))::int as invalid_pricing_mode,
    count(*) filter(where c.discount_pct<0 or c.discount_pct>=100)::int as invalid_discount_pct,
    count(*) filter(where c.pricing_mode='study')::int as pricing_mode_study,
    count(*) filter(where c.pricing_mode='discount')::int as pricing_mode_discount,
    count(*) filter(where c.pricing_mode='item_prices')::int as pricing_mode_item_prices
  from public.mo_contracts c
  left join contract_item_totals t on t.contract_id=c.id
  left join public.locked_studies s on s.id=c.source_study_id
),
order_totals as (
  select
    o.contract_id,
    round(coalesce(sum(o.subtotal) filter(where o.status in ('issued','sent','received')),0),2) as committed_net
  from public.mo_orders o
  group by o.contract_id
),
order_violations as (
  select
    count(*) filter(where coalesce(x.committed_net,0)>c.total_amount+0.005)::int
      as contracts_with_orders_above_actual_contract_total,
    coalesce(max(coalesce(x.committed_net,0)-c.total_amount),0) as max_contract_overrun
  from public.mo_contracts c
  left join order_totals x on x.contract_id=c.id
),
custom_values as (
  select
    oi.id as order_item_id,
    oi.order_id,
    oi.line_total,
    round(coalesce(sum(
      case when coalesce(mp.value->>'qty','') ~ '^[+]?[0-9]+([.][0-9]+)?$'
        then (mp.value->>'qty')::numeric*coalesce(ci.unit_price,0) else 0 end
    ),0),2) as mapped_value,
    count(mp.value)::int as mapping_entries
  from public.mo_order_items oi
  join public.mo_orders o on o.id=oi.order_id
  left join lateral jsonb_array_elements(
    case when oi.mapping is not null and jsonb_typeof(oi.mapping::jsonb)='array'
      then oi.mapping::jsonb else '[]'::jsonb end
  ) mp(value) on true
  left join public.mo_contract_items ci
    on ci.id::text=mp.value->>'contract_item_id' and ci.contract_id=o.contract_id
  where oi.is_custom is true and o.status in ('issued','sent','received')
  group by oi.id,oi.order_id,oi.line_total
),
custom_violations as (
  -- Η αντιστοίχιση δεν απαιτείται να ισούται σε αξία με την ελεύθερη γραμμή:
  -- αναλώνει συμβατικές ΠΟΣΟΤΗΤΕΣ, ενώ το ΧΡΗΜΑ δεσμεύεται από το subtotal του
  -- δελτίου. Παραβίαση είναι μόνο η εκδοθείσα ελεύθερη γραμμή χωρίς καμία
  -- αντιστοίχιση· η διαφορά αξίας καταγράφεται ως πληροφορία.
  select
    count(*)::int as issued_custom_lines,
    count(*) filter(where mapping_entries=0)::int as custom_charge_as_missing_mapping,
    coalesce(max(abs(mapped_value-coalesce(line_total,0))),0) as max_custom_value_difference
  from custom_values
),
cap_scopes as (
  select
    s.request_year,s.award_group_id,s.group_id,
    round(coalesce(sum(s.net_total),0),2) as estimated_committed,
    max(c.direct_award_cap) as cap
  from public.locked_studies s
  join public.award_groups g on g.id=s.award_group_id
  join public.award_group_configurations c on c.id=g.configuration_id
  where s.record_status='active'
  group by s.request_year,s.award_group_id,s.group_id
),
cap_checks as (
  select
    count(*)::int as active_scopes,
    count(*) filter(where estimated_committed>cap+0.005)::int as scopes_over_cap,
    count(*) filter(where cap is distinct from 30000::numeric)::int as scopes_with_non_30000_cap,
    coalesce(max(estimated_committed),0) as max_estimated_committed
  from cap_scopes
),
decision_current as (
  select c.*,
    public.app_award_group_configuration_is_canonical(c.budget_year) as canonical_groups,
    (upper(btrim(c.decision_ada)) ~ '^[0-9A-ZΑ-Ω]+-[0-9A-ZΑ-Ω]+$') as ada_format_valid,
    (c.decision_date<=current_date) as decision_date_not_future
  from public.award_group_configurations c
  where c.is_active
  order by c.budget_year desc,c.id desc
  limit 1
),
decision_json as (
  select jsonb_build_object(
    'budget_year',d.budget_year,
    'decision_number',d.decision_number,
    'decision_date',d.decision_date,
    'decision_ada',d.decision_ada,
    'direct_award_cap',d.direct_award_cap,
    'canonical_groups',d.canonical_groups,
    'ada_format_valid',d.ada_format_valid,
    'decision_date_not_future',d.decision_date_not_future,
    'human_official_record_confirmation_required',true
  ) as value
  from decision_current d
),
catalog as (
  select
    count(*) filter(where g.domain='procurement' and m.is_active)::int as procurement_items,
    count(*) filter(where g.domain='service' and m.is_active)::int as service_items,
    count(*) filter(where g.domain='procurement' and m.is_active and coalesce(trim(m.technical_specs),'')='')::int as procurement_missing_specs,
    count(*) filter(where g.domain='service' and m.is_active and coalesce(trim(m.technical_specs),'')='')::int as service_missing_specs
  from public.materials m join public.procurement_groups g on g.id=m.group_id
)
select jsonb_pretty(jsonb_build_object(
  'verified_at',now(),
  'schema',to_jsonb(schema_objects),
  'triggers',to_jsonb(trigger_checks),
  'function_checks',to_jsonb(function_checks),
  'contract_economics',to_jsonb(contract_violations),
  'order_economics',to_jsonb(order_violations),
  'custom_charge_as',to_jsonb(custom_violations),
  'direct_award_cap',to_jsonb(cap_checks),
  'decision_metadata',coalesce(decision_json.value,'{}'::jsonb),
  'catalog',to_jsonb(catalog),
  'expected',jsonb_build_object(
    'schema_version','36.6.5',
    'pricing_rpc_exists',true,
    'decision_metadata_rpc_exists',true,
    'all_pricing_guards',true,
    'original_contract_items_immutable_guard_preserved',true,
    'contract_above_estimate',0,
    'contract_total_vs_items_mismatch',0,
    'contract_estimate_vs_locked_study_mismatch',0,
    'contracts_with_orders_above_actual_contract_total',0,
    'custom_charge_as_missing_mapping',0,
    'scopes_over_cap',0,
    'scopes_with_non_30000_cap',0,
    'canonical_groups',true,
    'ada_format_valid',true,
    'decision_date_not_future',true,
    'procurement_missing_specs',0,
    'service_missing_specs',0,
    'note','Η ταύτιση αριθμού απόφασης και ΑΔΑ με το επίσημο διοικητικό έγγραφο απαιτεί ανθρώπινη επιβεβαίωση· ο verifier δεν επινοεί διοικητικά στοιχεία.'
  )
)) as v36_6_5_verification
from schema_objects,trigger_checks,function_checks,contract_violations,
     order_violations,custom_violations,cap_checks,decision_json,catalog;
