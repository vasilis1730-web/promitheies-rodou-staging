-- ============================================================================
-- v36.6.6 — contract entry-point hardening
-- Οι παλιές contract write RPCs παραμένουν διαθέσιμες μόνο για εσωτερικές
-- SECURITY DEFINER κλήσεις. Ο browser/authenticated ρόλος πρέπει να περνά από
-- save_contract_pricing_resilient_atomic() ώστε να ισχύει idempotency.
-- ============================================================================

begin;

revoke execute on function public.save_contract_atomic(
  text,text,text,text,text,text,date,date,numeric
) from authenticated;

revoke execute on function public.save_contract_pricing_atomic(
  text,text,text,text,text,text,date,date,numeric,text,numeric,jsonb
) from authenticated;

commit;
