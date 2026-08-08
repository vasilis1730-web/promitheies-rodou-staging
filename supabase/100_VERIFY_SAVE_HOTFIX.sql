-- Αναγνωστικός έλεγχος του hotfix αποθήκευσης. Δεν μεταβάλλει δεδομένα.
select
  public.app_schema_version() as schema_version,
  format_type(a.atttypid, a.atttypmod) as request_status_column_type,
  pg_get_functiondef(
    'public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)'::regprocedure
  ) like '%v_status public.unit_requests.status%type;%' as save_hotfix_installed,
  has_function_privilege(
    'authenticated',
    'public.save_unit_request_atomic(text,bigint,bigint,integer,text,text,jsonb)',
    'EXECUTE'
  ) as authenticated_can_execute
from pg_attribute a
where a.attrelid = 'public.unit_requests'::regclass
  and a.attname = 'status'
  and a.attnum > 0
  and not a.attisdropped;
