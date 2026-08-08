-- Αναγνωστικός έλεγχος του hotfix της Δ.Ε. Αταβύρου. Δεν μεταβάλλει δεδομένα.
select
  public.app_schema_version() as schema_version,
  public.app_rhodes_municipal_unit_code(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΑΒΥΡΟΥ'
  ) as single_t_name_code,
  public.app_rhodes_municipal_unit_code(
    'Αττάβυρος', 'Ατταβύρου'
  ) as double_t_name_code,
  public.app_rhodes_award_group_no(
    'ΔΗΜΟΤΙΚΗ ΕΝΟΤΗΤΑ ΑΤΑΒΥΡΟΥ', 'ΑΤΑΒΥΡΟΥ'
  ) as atavyros_group_no,
  (select count(*) from public.app_rhodes_award_group_template()) as rhodes_template_units,
  (select count(distinct group_no)
     from public.app_rhodes_award_group_template()) as rhodes_template_groups;
