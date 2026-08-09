# Φάση 5 — Supabase RLS / Privilege Audit

## Baseline

Audit target: staging schema `36.6.6`.

Observed from the read-only `pg_catalog` inventory:

- 30/30 `public` tables have RLS enabled.
- `anon` has zero direct table access.
- `anon` and `authenticated` are neither superusers nor `BYPASSRLS` roles.
- Browser roles cannot `CREATE` in schema `public`.
- All four authenticated views are `security_invoker=true`.
- No exposed non-invoker/materialized view was found.
- No `SECURITY DEFINER` function was found without a pinned `search_path`.
- No `SECURITY DEFINER` function was executable by `anon`.
- `app_operation_idempotency` intentionally has RLS with no permissive policy and no direct browser grants (deny-by-default).
- 18 non-`SECURITY DEFINER` functions were executable through `PUBLIC`/`anon`; these were mostly trigger/validation helpers and are unnecessary browser RPC surface.
- PostgreSQL/Supabase default ACL behavior could accidentally expose future app objects unless each later migration remembers explicit revokes.
- Two legacy tables, `mo_projects` and `mo_counters`, retained permissive authenticated policies although the current frontend does not reference them.

Initial structural audit result: **0 CRITICAL findings**.

## Authorization review of elevated RPCs

The main browser-facing `SECURITY DEFINER` operations were checked against their SQL definitions. Critical write routes perform server-side authorization instead of trusting UI state, including:

- request writes via `app_can_write_unit(...)`;
- study metadata amendment/cancellation via `app_is_admin()`;
- order issuance/writes via unit authorization;
- cancellation of issued orders via `app_is_admin()`;
- draft deletion via unit authorization plus creator/admin ownership;
- admin purge and template administration via `app_is_admin()`;
- user credential/permission administration via admin checks;
- award-group configuration/metadata changes via admin checks;
- Excel export token issuance via unit read authorization;
- Excel import via admin authorization, user-bound token, context binding, expiry and single-use checks;
- v36.6.6 resilient entrypoints preserve the underlying authorization while adding idempotency/concurrency protection.

## Hardening applied by migration 202608090008

1. Revoke current `EXECUTE` on all `public` functions from `PUBLIC` and `anon`.
2. Revoke all current direct `public` table/sequence privileges from `anon`.
3. Change **postgres-owned future app defaults** in schema `public` to opt-in for functions, tables and sequences.
4. Remove authenticated direct access and permissive policies from unused `mo_projects` / `mo_counters`.
5. Preserve existing explicit `authenticated` grants for the active application RPCs and RLS helpers.
6. Keep application compatibility version at `36.6.6`; this hardening changes ACL/policy surface, not the frontend RPC contract.

## Supplier / receiver directory privacy

`mo_suppliers` and `mo_receivers` are currently shared directories for active authenticated users. The frontend deliberately loads both directories without a municipal-unit filter. This exposes supplier contact/AFM fields and receiver contact fields to all active application users.

This is **not treated as an RLS bypass** because the policy matches the current frontend behavior and inactive/anonymous users remain blocked. It is a separate business/privacy policy decision:

- keep municipality-wide shared directories; or
- redesign the tables with municipal-unit ownership/scoping and update the frontend accordingly.

No silent data-model change is made by the privilege-hardening migration.

## Deployment gate

Do not merge the Phase 5 branch until:

1. repository CI passes on the final branch head;
2. migration `202608090008_phase5_rls_privilege_hardening.sql` succeeds on staging;
3. `115_VERIFY_PHASE5_RLS_PRIVILEGE_HARDENING.sql` returns `phase5_privilege_hardening_ready = true`;
4. browser smoke confirms login, catalog loading, study/order workflows and admin controls remain available.
