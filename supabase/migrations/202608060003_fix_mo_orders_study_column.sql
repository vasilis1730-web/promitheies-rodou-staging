-- v36.5.5 BULLETINS SCHEMA HOTFIX
--
-- Το αρχικό πλήρες installer δημιούργησε τη σύνδεση mo_orders ->
-- locked_studies ως source_study_id, ενώ το frontend και οι ατομικές
-- συναρτήσεις της v36.2 χρησιμοποιούν study_id. Η ασυμβατότητα προκαλεί
-- αποτυχία της φόρτωσης της ενότητας «Δελτία Υλικών & Εργασιών».
--
-- Η migration είναι επαναλήψιμη. Στη συνήθη εγκατάσταση μετονομάζει τη
-- στήλη, οπότε PostgreSQL διατηρεί αυτόματα δεδομένα, FK και υφιστάμενους
-- δείκτες. Αν συνυπάρχουν προσωρινά και οι δύο στήλες, συμπληρώνει με
-- ασφάλεια την canonical study_id χωρίς να διαγράψει τη legacy στήλη.

begin;

do $$
declare
  v_schema_version text;
  v_has_source boolean;
  v_has_study boolean;
begin
  select public.app_schema_version() into v_schema_version;
  if v_schema_version is distinct from '36.5.5' then
    raise exception 'Απαιτείται schema 36.5.5 για το BULLETINS SCHEMA HOTFIX. Βρέθηκε: %',
      coalesce(v_schema_version, 'NULL');
  end if;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'mo_orders'
      and column_name = 'source_study_id'
  ) into v_has_source;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'mo_orders'
      and column_name = 'study_id'
  ) into v_has_study;

  if v_has_source and not v_has_study then
    alter table public.mo_orders rename column source_study_id to study_id;
  elsif v_has_source and v_has_study then
    if exists (
      select 1
      from public.mo_orders
      where study_id is not null
        and source_study_id is not null
        and study_id::text <> source_study_id::text
    ) then
      raise exception 'Βρέθηκαν αντικρουόμενες συνδέσεις study_id/source_study_id στον πίνακα mo_orders. Δεν έγινε καμία αλλαγή.';
    end if;

    update public.mo_orders
    set study_id = source_study_id
    where study_id is null
      and source_study_id is not null;
  elsif not v_has_study then
    raise exception 'Ο πίνακας public.mo_orders δεν διαθέτει ούτε study_id ούτε source_study_id. Δεν έγινε καμία αλλαγή.';
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint c
    join unnest(c.conkey) as key(attnum) on true
    join pg_attribute a
      on a.attrelid = c.conrelid
     and a.attnum = key.attnum
    where c.conrelid = 'public.mo_orders'::regclass
      and c.confrelid = 'public.locked_studies'::regclass
      and c.contype = 'f'
      and a.attname = 'study_id'
  ) then
    alter table public.mo_orders
      add constraint mo_orders_study_id_fkey_v3655
      foreign key (study_id)
      references public.locked_studies(id)
      on delete restrict
      not valid;

    alter table public.mo_orders
      validate constraint mo_orders_study_id_fkey_v3655;
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'mo_orders'
      and indexdef ilike '%(study_id)%'
  ) then
    create index idx_mo_orders_study_id_v3655
      on public.mo_orders(study_id);
  end if;
end;
$$;

comment on column public.mo_orders.study_id is
  'Κλειδωμένη μελέτη από την οποία εκδόθηκε το δελτίο.';

notify pgrst, 'reload schema';

commit;
