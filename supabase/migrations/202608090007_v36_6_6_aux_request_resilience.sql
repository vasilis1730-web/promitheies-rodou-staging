-- ============================================================================
-- v36.6.6 — auxiliary draft-write resilience
--
-- Καλύπτει δύο διαδρομές που επίσης μεταβάλλουν unit_requests:
--   * αντιγραφή ομάδας σε άλλη Δ.Ε.
--   * φόρτωση προτύπου σε επεξεργάσιμο πρόχειρο
-- Και οι δύο αποκτούν operation_id + optimistic revision.
-- ============================================================================

begin;

create or replace function public.copy_unit_request_resilient_atomic(
  p_operation_id uuid,
  p_expected_destination_revision bigint,
  p_source_municipal_unit_id bigint,
  p_destination_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer,
  p_title text,
  p_lines jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
  v_request_id public.unit_requests.id%type;
  v_revision bigint;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'source_municipal_unit_id',p_source_municipal_unit_id,
    'destination_municipal_unit_id',p_destination_municipal_unit_id,
    'group_id',p_group_id,'request_year',p_request_year,'title',p_title,'lines',p_lines,
    'expected_destination_revision',p_expected_destination_revision
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'copy_unit_request',v_fp);
  if v_replay is not null then return v_replay; end if;

  -- Σειριοποιεί και την πρώτη δημιουργία πρόχειρου στον προορισμό.
  perform u.id from public.municipal_units u
  where u.id::bigint=p_destination_municipal_unit_id for update;

  select r.id,r.revision into v_request_id,v_revision
  from public.unit_requests r
  where r.municipal_unit_id::bigint=p_destination_municipal_unit_id
    and r.group_id::bigint=p_group_id
    and r.request_year=p_request_year
  for update;

  if v_request_id is null then
    if coalesce(p_expected_destination_revision,0)<>0 then
      raise exception using errcode='40001',message='Το πρόχειρο προορισμού δημιουργήθηκε ή άλλαξε από άλλο χρήστη. Ανανεώστε πριν από την αντιγραφή.';
    end if;
  elsif p_expected_destination_revision is null or p_expected_destination_revision<>v_revision then
    raise exception using errcode='40001',message='Το πρόχειρο προορισμού άλλαξε από άλλο χρήστη. Η αντιγραφή δεν εφαρμόστηκε.';
  end if;

  v_result:=public.copy_unit_request_atomic(
    p_source_municipal_unit_id,p_destination_municipal_unit_id,p_group_id,
    p_request_year,p_title,p_lines
  );

  update public.unit_requests r
  set revision=r.revision+1
  where r.id::text=v_result->>'request_id'
  returning revision into v_revision;

  v_result:=v_result||jsonb_build_object('revision',v_revision,'replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.copy_unit_request_resilient_atomic(uuid,bigint,bigint,bigint,bigint,integer,text,jsonb)
  from public,anon;
grant execute on function public.copy_unit_request_resilient_atomic(uuid,bigint,bigint,bigint,bigint,integer,text,jsonb)
  to authenticated;

create or replace function public.load_study_template_resilient_atomic(
  p_operation_id uuid,
  p_expected_revision bigint,
  p_template_id text,
  p_municipal_unit_id bigint,
  p_group_id bigint,
  p_request_year integer
)
returns jsonb
language plpgsql
security definer
set search_path=public,pg_temp
set row_security=off
as $$
declare
  v_fp text;
  v_replay jsonb;
  v_result jsonb;
  v_request_id public.unit_requests.id%type;
  v_revision bigint;
begin
  v_fp:=public.app_operation_fingerprint(jsonb_build_object(
    'template_id',p_template_id,'municipal_unit_id',p_municipal_unit_id,
    'group_id',p_group_id,'request_year',p_request_year,
    'expected_revision',p_expected_revision
  ));
  v_replay:=public.app_operation_claim(p_operation_id,'load_study_template',v_fp);
  if v_replay is not null then return v_replay; end if;

  perform u.id from public.municipal_units u
  where u.id::bigint=p_municipal_unit_id for update;

  select r.id,r.revision into v_request_id,v_revision
  from public.unit_requests r
  where r.municipal_unit_id::bigint=p_municipal_unit_id
    and r.group_id::bigint=p_group_id
    and r.request_year=p_request_year
  for update;

  if v_request_id is null then
    if coalesce(p_expected_revision,0)<>0 then
      raise exception using errcode='40001',message='Το πρόχειρο δημιουργήθηκε ή άλλαξε πριν από τη φόρτωση του προτύπου. Ανανεώστε.';
    end if;
  elsif p_expected_revision is null or p_expected_revision<>v_revision then
    raise exception using errcode='40001',message='Το πρόχειρο άλλαξε από άλλο χρήστη. Το πρότυπο δεν φορτώθηκε.';
  end if;

  v_result:=public.load_study_template_atomic(
    p_template_id,p_municipal_unit_id,p_group_id,p_request_year
  );

  update public.unit_requests r
  set revision=r.revision+1
  where r.id::text=v_result->>'request_id'
  returning revision into v_revision;

  v_result:=v_result||jsonb_build_object('revision',v_revision,'replayed',false);
  return public.app_operation_complete(p_operation_id,v_result);
end;
$$;

revoke all on function public.load_study_template_resilient_atomic(uuid,bigint,text,bigint,bigint,integer)
  from public,anon;
grant execute on function public.load_study_template_resilient_atomic(uuid,bigint,text,bigint,bigint,integer)
  to authenticated;

-- Browser access only through resilient wrappers.
revoke execute on function public.copy_unit_request_atomic(bigint,bigint,bigint,integer,text,jsonb)
  from authenticated;
revoke execute on function public.load_study_template_atomic(text,bigint,bigint,integer)
  from authenticated;

commit;
