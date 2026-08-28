-- ============================================================================
-- ΔΗΜΟΣ ΡΟΔΟΥ — ΑΠΟΔΟΣΗ ΡΟΛΩΝ ΚΑΙ ΔΗΜΟΤΙΚΩΝ ΕΝΟΤΗΤΩΝ ΣΤΟΥΣ ΧΡΗΣΤΕΣ
--
-- ΓΙΑΤΙ ΧΡΕΙΑΖΕΤΑΙ
--   Ο λογαριασμός δημιουργείται στο Supabase Dashboard. Το trigger
--   on_auth_user_created φτιάχνει αυτόματα προφίλ, αλλά με ρόλο 'viewer' και
--   ΧΩΡΙΣ Δημοτική Ενότητα — δηλαδή ο χρήστης μπαίνει και δεν μπορεί να
--   κάνει τίποτα. Η εφαρμογή δεν αλλάζει ρόλο ή Δ.Ε. από καμία οθόνη.
--   Το παρόν αρχείο κάνει ακριβώς αυτό το βήμα.
--
-- ΑΣΦΑΛΕΙΑ
--   * Εκτελείται σε μία συναλλαγή· αν κάτι λείπει, δεν αλλάζει τίποτα.
--   * Σταματά αν κάποιος λογαριασμός δεν έχει δημιουργηθεί ακόμη.
--   * Σταματά αν κάποιος λογαριασμός δεν είναι επιβεβαιωμένος.
--   * Επαναλήψιμο: δεύτερη εκτέλεση δεν αλλάζει τίποτα.
--   * Δεν αγγίζει κανέναν χρήστη εκτός της παρακάτω λίστας.
--
-- ΠΡΟΣΘΗΚΗ ΝΕΩΝ ΧΡΗΣΤΩΝ
--   Δημιούργησε πρώτα τον λογαριασμό στο Dashboard (Authentication → Users →
--   Add user, με Auto Confirm User), πρόσθεσε γραμμή στο roster και ξανατρέξε.
--
-- ΕΠΙΤΡΕΠΤΟΙ ΣΥΝΔΥΑΣΜΟΙ (constraint profile_role_unit_consistency)
--   unit_user → Δ.Ε. 1..10   ·   central → 11   ·   admin/viewer → κενό
--   1 Αρχαγγέλου · 2 Αταβύρου · 3 Αφάντου · 4 Ιαλυσού · 5 Καλλιθέας
--   6 Καμείρου · 7 Λινδίων · 8 Νότιας Ρόδου · 9 Πεταλουδών · 10 Ρόδου
--   11 Δήμος Ρόδου (κεντρική)
-- ============================================================================

begin;

create temporary table roster (
  email text primary key,
  new_role text not null,
  new_unit smallint
) on commit drop;

insert into roster (email, new_role, new_unit) values
  ('diakolios@rhodes.gr',          'central',   11),
  ('mkanakas@gmail.com',           'unit_user', 10),
  ('mkarikispromithies@gmail.com', 'unit_user', 10),
  ('abekiaris@rhodes.gr',          'central',   11);

do $$
declare
  v_missing text;
  v_unconfirmed text;
  v_bad text;
begin
  -- Λογαριασμοί που δεν έχουν δημιουργηθεί ακόμη στο Dashboard.
  select string_agg(r.email, ', ' order by r.email) into v_missing
  from roster r
  where not exists (select 1 from auth.users u where lower(u.email) = lower(r.email));
  if v_missing is not null then
    raise exception 'Δεν υπάρχουν ακόμη λογαριασμοί για: %. Δημιούργησέ τους στο Supabase Dashboard (Authentication → Users → Add user, με Auto Confirm User) και ξανατρέξε το αρχείο.', v_missing;
  end if;

  -- Η εφαρμογή δέχεται μόνο επιβεβαιωμένους χρήστες.
  select string_agg(u.email, ', ' order by u.email) into v_unconfirmed
  from roster r join auth.users u on lower(u.email) = lower(r.email)
  where u.email_confirmed_at is null;
  if v_unconfirmed is not null then
    raise exception 'Μη επιβεβαιωμένοι λογαριασμοί: %. Ενεργοποίησε το Auto Confirm ή επιβεβαίωσέ τους πριν συνεχίσεις.', v_unconfirmed;
  end if;

  -- Ο συνδυασμός ρόλου/Δ.Ε. ελέγχεται εδώ, με σαφές μήνυμα αντί για
  -- σκέτη παραβίαση constraint.
  select string_agg(format('%s → %s/%s', r.email, r.new_role, coalesce(r.new_unit::text, 'κενό')), ', ' order by r.email)
    into v_bad
  from roster r
  where not (
    (r.new_role = 'unit_user' and r.new_unit between 1 and 10)
    or (r.new_role = 'central' and r.new_unit = 11)
    or (r.new_role in ('admin', 'viewer') and r.new_unit is null)
  );
  if v_bad is not null then
    raise exception 'Μη επιτρεπτός συνδυασμός ρόλου/Δ.Ε.: %. Επιτρέπονται: unit_user→1..10, central→11, admin/viewer→κενό.', v_bad;
  end if;
end $$;

update public.profiles p
set role              = r.new_role::public.app_role,
    municipal_unit_id = r.new_unit,
    is_active         = true
from roster r
join auth.users u on lower(u.email) = lower(r.email)
where p.id = u.id
  and (p.role is distinct from r.new_role::public.app_role
       or p.municipal_unit_id is distinct from r.new_unit
       or p.is_active is not true);

-- Αναφορά: η τελική κατάσταση κάθε χρήστη του roster.
select
  u.email                                    as "Λογαριασμός",
  p.role::text                               as "Ρόλος",
  coalesce(mu.short_name, '—')               as "Δημοτική Ενότητα",
  p.is_active                                as "Ενεργός"
from roster r
join auth.users u on lower(u.email) = lower(r.email)
join public.profiles p on p.id = u.id
left join public.municipal_units mu on mu.id = p.municipal_unit_id
order by p.role::text, u.email;

commit;
