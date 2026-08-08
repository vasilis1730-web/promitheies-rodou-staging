-- Αναγνωστικός έλεγχος του διορθωτικού αντιστοίχισης ομάδων.
-- Δεν μεταβάλλει δεδομένα.
select
  public.app_schema_version() as schema_version,
  public.app_rhodes_municipal_unit_code(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', 'ΝΟΤΙΑΣ ΡΟΔΟΥ'
  ) as south_rhodes_genitive_code,
  public.app_rhodes_award_group_no(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΝΟΤΙΑΣ ΡΟΔΟΥ', 'ΝΟΤΙΑΣ ΡΟΔΟΥ'
  ) as south_rhodes_group_no,
  public.app_rhodes_municipal_unit_code(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', 'ΡΟΔΟΥ'
  ) as rhodes_code,
  public.app_rhodes_award_group_no(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΡΟΔΟΥ', 'ΡΟΔΟΥ'
  ) as rhodes_group_no,
  public.app_rhodes_municipal_unit_code(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΑΒΥΡΟΥ'
  ) as atavyros_single_t_code,
  (select count(*) from public.app_rhodes_award_group_template()) as rhodes_template_units,
  (select count(distinct public.app_rhodes_municipal_unit_code(u.name, u.short_name))
     from public.municipal_units u
    where u.id::bigint <> 11) as distinct_unit_codes,
  (select count(*) from public.app_rhodes_award_group_template() where group_no = 1) as group_1_units,
  (select count(*) from public.app_rhodes_award_group_template() where group_no = 2) as group_2_units,
  (select count(*) from public.app_rhodes_award_group_template() where group_no = 3) as group_3_units,
  (select count(*) from public.app_rhodes_award_group_template() where group_no = 4) as group_4_units;
