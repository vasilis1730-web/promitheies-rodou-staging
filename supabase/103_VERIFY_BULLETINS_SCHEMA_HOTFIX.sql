-- Αναγνωστικός έλεγχος μετά το 202608060003_fix_mo_orders_study_column.sql.
-- Δεν μεταβάλλει δεδομένα.

select
  public.app_schema_version() as schema_version,
  (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'mo_orders'
      and column_name = 'study_id'
  ) as canonical_study_column,
  (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'mo_orders'
      and column_name = 'source_study_id'
  ) as legacy_source_study_column,
  (
    select count(*)
    from pg_constraint c
    join unnest(c.conkey) as key(attnum) on true
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum = key.attnum
    where c.conrelid = 'public.mo_orders'::regclass
      and c.confrelid = 'public.locked_studies'::regclass
      and c.contype = 'f'
      and a.attname = 'study_id'
  ) as canonical_study_fk,
  (
    select count(*)
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'mo_orders'
      and indexdef ilike '%(study_id)%'
  ) as canonical_study_indexes,
  (
    select count(*)
    from public.locked_studies
    where record_status = 'active'
  ) as active_locked_studies,
  (
    select count(*)
    from public.mo_orders o
    left join public.locked_studies s on s.id = o.study_id
    where o.study_id is not null
      and s.id is null
  ) as orphan_orders;

select
  s.id as study_id,
  s.seq,
  s.request_year,
  mu.short_name as municipal_unit,
  pg.short_name as study_group,
  pg.domain,
  s.net_total,
  s.record_status,
  s.locked_at
from public.locked_studies s
join public.municipal_units mu on mu.id = s.municipal_unit_id
join public.procurement_groups pg on pg.id = s.group_id
where s.record_status = 'active'
order by s.locked_at desc;
