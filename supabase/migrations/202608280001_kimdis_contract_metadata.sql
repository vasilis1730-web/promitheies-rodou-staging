-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΜΕΤΑΔΕΔΟΜΕΝΑ ΚΗΜΔΗΣ ΣΤΗ ΣΥΜΒΑΣΗ
--
-- Η «Καταχώριση ανάθεσης» αντλεί τα επίσημα στοιχεία της σύμβασης από το
-- ΚΗΜΔΗΣ. Μέχρι τώρα αξιοποιούνταν μόνο όσα χωρούσαν στα υπάρχοντα πεδία·
-- τα υπόλοιπα (CPV, Α/Α ΕΣΗΔΗΣ, ΑΔΑ, νομικό πλαίσιο, χρηματοδότηση,
-- προειδοποιήσεις ακύρωσης) χάνονταν.
--
-- Αποθηκεύεται ολόκληρη η κανονικοποιημένη απάντηση ως jsonb. Έτσι:
--   * κανένα πεδίο του API δεν χάνεται, ακόμη κι αν προστεθούν νέα,
--   * υπάρχει τεκμήριο του τι ακριβώς είπε το ΚΗΜΔΗΣ και πότε.
--
-- Η εγγραφή γίνεται από ατομική SECURITY DEFINER συνάρτηση, όπως κάθε άλλη
-- εγγραφή της εφαρμογής: ο ρόλος authenticated δεν γράφει απευθείας.
-- ============================================================================

begin;

alter table public.mo_contracts
  add column if not exists kimdis jsonb,
  add column if not exists kimdis_fetched_at timestamptz;

comment on column public.mo_contracts.kimdis is
  'Κανονικοποιημένα μεταδεδομένα ΚΗΜΔΗΣ της σύμβασης, όπως αντλήθηκαν με τον ΑΔΑΜ.';

create or replace function public.set_contract_kimdis(
  p_contract_id text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_unit smallint;
  v_role public.app_role;
  v_unit_of_user smallint;
begin
  begin
    v_id := p_contract_id::uuid;
  exception when others then
    raise exception 'Μη έγκυρο αναγνωριστικό σύμβασης.';
  end;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Τα μεταδεδομένα ΚΗΜΔΗΣ πρέπει να είναι αντικείμενο JSON.';
  end if;

  select role, municipal_unit_id into v_role, v_unit_of_user
  from public.profiles where id = auth.uid() and is_active;
  if v_role is null then
    raise exception 'Δεν υπάρχει ενεργό προφίλ χρήστη.';
  end if;

  select municipal_unit_id into v_unit from public.mo_contracts where id = v_id;
  if v_unit is null and not exists (select 1 from public.mo_contracts where id = v_id) then
    raise exception 'Η σύμβαση δεν βρέθηκε.';
  end if;

  -- Ίδιος κανόνας πρόσβασης με τις υπόλοιπες εγγραφές δελτίων/συμβάσεων:
  -- ο χρήστης Δ.Ε. μόνο στη δική του ενότητα, admin και central παντού.
  if v_role = 'unit_user' and (v_unit is null or v_unit is distinct from v_unit_of_user) then
    raise exception 'Δεν έχετε δικαίωμα σε σύμβαση άλλης Δημοτικής Ενότητας.';
  end if;
  if v_role = 'viewer' then
    raise exception 'Ο ρόλος προβολής δεν καταχωρίζει στοιχεία.';
  end if;

  update public.mo_contracts
  set kimdis = p_payload,
      kimdis_fetched_at = now(),
      updated_at = now()
  where id = v_id;

  return jsonb_build_object('contract_id', v_id, 'stored', true);
end;
$$;

revoke all on function public.set_contract_kimdis(text, jsonb) from public, anon;
grant execute on function public.set_contract_kimdis(text, jsonb) to authenticated;

commit;
