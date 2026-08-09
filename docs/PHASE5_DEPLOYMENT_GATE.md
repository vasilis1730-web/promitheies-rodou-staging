# Phase 5 deployment gate

Do not merge the Phase 5 branch until all gates are green:

1. Final branch CI passes.
2. Apply `202608090008_phase5_rls_privilege_hardening.sql` on staging schema 36.6.6.
3. Run `115_VERIFY_PHASE5_RLS_PRIVILEGE_HARDENING.sql`.
4. Require `phase5_privilege_hardening_ready = true` and every boolean check = true.
5. Smoke-test login, catalogs, study history, Excel token/export, admin management and material-order module.
6. Make/record the separate supplier/receiver directory privacy decision; it is not silently changed by this hardening migration.
7. Only then merge/deploy.
