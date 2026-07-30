# BespokeLMS — database migrations

Declarative SQL migrations for the BespokeLMS Supabase/Postgres project
(`pqmdtqsscyltykgcwwus`, region eu-west-1). Numbered; **apply in order**.

## How to apply

These can be run in the Supabase SQL Editor (open each file, paste it into a
new query, run it, then move to the next number) — each migration is additive
and safe to run once on top of the previous ones. The Supabase MCP connector
can now also reach the BespokeLMS org, so migrations may alternatively be
applied via `apply_migration` (which records them in
`supabase_migrations.schema_migrations`).

Conventions: snake_case names, `timestamptz`, ISO-8601 dates, lowercase
reserved words, Row-Level Security on every table cascading down the
`organizations` tree, secret columns encrypted server-side (never read by the
browser). Service-role (server) code bypasses RLS for seeding and privileged
Laravel operations; the anon/publishable key is constrained by the policies.

## Migrations

| # | File | What it does | Status |
|---|------|--------------|--------|
| 001 | `001_bespokelms_schema.sql` | Core multi-tenant schema — enums, `organizations` tree, `teams`, `profiles`, RBAC helper functions, `courses`/`categories`/`enrollments`/`certificates`, engagement + admin tables, compliance views, RLS, grants. | Applied (live) |
| 002 | `002_bespokelms_seed.sql` | Mock/demo seed — 13 categories, 28 courses, the 8-org tenant tree, teams, demo accounts, enrolments, requirements, branding, ideas, notifications. | Applied (live) |
| 003 | `003_bespokelms_course_content.sql` | **Global Courses · Phase 1 — content model.** `courses` becomes an identity shell; adds `course_versions` (immutable-on-publish, semver) → `modules` → `lessons` → `slides` (image_text/video/document, typed jsonb payload) + `content_translations` (per-locale). Pins `enrollments` to a version. Full-text (`tsvector`+GIN) and trigram search. Backfills the 28 seeded courses into v1 versions. | Ready to apply |
| 004 | `004_bespokelms_course_visibility.sql` | **Phase 2 — tenant visibility & entitlement.** `course_visibility` (global/allowlist/private/denylist) + `course_entitlements` (inherit down the org tree) + `can_see_course()`. Tightens catalogue reads onto this model so one tenant can't see another's private courses. | Ready to apply |
| 005 | `005_bespokelms_course_workflow.sql` | **Phase 4 — the planning tool.** Data-driven workflow state machine (Draft→In Review→Approved→Published→Review Due→Retired), per-course author/reviewer/approver, separation of duties, sign-off checklist (publish gate), and the review-date engine. Seeds the default workflow + checklist and backfills every version into its state. | Ready to apply |
| 006 | `006_bespokelms_course_taxonomy.sql` | **Phase 7 — taxonomy with per-tenant override.** Evolves `course_categories` into the global dictionary; adds `tags`/`course_tags` and the per-tenant overlays (`tenant_category_overrides`, `tenant_tags`, `tenant_course_overrides`) with COALESCE resolution helpers, so each tenant can categorise its own way without forking the global set. | Ready to apply |
| 007 | `007_bespokelms_course_editor.sql` | **Course editor fields.** Adds the authoring fields the course editor writes. | Ready to apply |
| 008 | `008_bespokelms_email_integrations.sql` | **Email delivery integration.** Owner-level email transport (`email_integrations` — Resend/Postmark/SES/SMTP/custom, secret encrypted, enabled row = platform default, provider-swappable) mirroring `ai_integrations`; per-tenant sender identities (`tenant_email_aliases`); delivery ledger (`email_send_logs`). Dual RLS: owner manages transport, tenant admins manage their own alias. Seeds the 5 unconfigured provider rows. | Applied (live) 2026-07-23 |

Apply order for the outstanding course work: **003 → 004 → 005 → 006 → 007**
(001, 002 and 008 are already live). 008 depends only on 001 (+ the owner-tier
policies), so it is independent of the 003–007 course chain.

## 281–289 — the commercial layer (quote to contract)

Applied to the live project on 2026-07-29 via the Supabase MCP, in this order.
Every one is additive; nothing existing changed behaviour.

Note on the table above: it documents 001–008 only. Migrations 009–280 were
added without extending it, so each file carries its own header explaining what
it does and why — that header is the record, not this index.

| # | File | What it does |
|---|------|--------------|
| 281 | `281_sales_product_catalogue_and_line_items.sql` | Tenant-scoped product catalogue and priced proposal lines. `esign_line_items.line_total_minor` is a **generated** column, so a stated total can never contradict its own unit price and quantity. Adds `sales_org_access()`, the tenant guard trigger, and `v_esign_document_totals`. |
| 282 | `282_email_engagement_tracking.sql` | Per-event opens and clicks (`email_engagement_events`), own-redirect tracked links, and a per-tenant switch that cannot be turned on without a recorded lawful basis. Confidence is a first-class column so mail-scanner activity is labelled, not believed. |
| 283 | `283_notification_domain_add_sales.sql` | Adds `sales` to `notification_domain`. Separate migration because Postgres will not let a new enum value be used in the transaction that adds it. |
| 284 | `284_contract_clause_library.sql` | Versioned, never-edited-in-place contract clauses; templates composed from them; and what a specific agreement actually used, pinned. `v_contract_clause_usage` answers "which live contracts still carry the old wording". |
| 285 | `285_negotiation_linkage_and_contracts.sql` | `mail_threads.deal_id` so a negotiation attaches to its opportunity; `crm_deal_offers` for offered/countered/agreed; and `contracts` + commitments + usage measurements, so term, renewal and committed minimums are data rather than prose. |
| 286 | `286_sales_notification_events.sql` | Four events: proposal opened, proposal link clicked, contract renewal notice due, contract usage measurement due. The two scheduled ones depend on the Laravel Cloud scheduler worker (bug `2cf06b8e`). |
| 287 | `287_commercial_layer_hardening.sql` | **Security fix.** The three new views ran with owner rights and read straight past row-level security — reported as ERROR by the Supabase advisor. `security_invoker = on` on all three, plus two mutable `search_path` functions pinned. |
| 288 | `288_revoke_public_execute_on_commercial_functions.sql` | 287's revokes did nothing: Postgres grants EXECUTE to PUBLIC by default, so revoking from `anon`/`authenticated` left the PUBLIC grant in place. Revoked from PUBLIC and granted back only `sales_org_access` to `authenticated`, which RLS policies need. |
| 289 | `289_bespokelms_product_catalogue_seed.sql` | The real BespokeLMS catalogue — configuration, platform licence, content licence, active user, bespoke course — taken from the executed Turner Price agreement. Not sample data. |

| 290 | `290_course_entitlements_contract_link.sql` | **Contractual entitlements are now identifiable.** Adds `course_entitlements.contract_id`, so a grant a contract obliges can be told apart from a discretionary one — and protected from the course editor's replace-all licensing save, which previously deleted every entitlement for a course and rebuilt it from the form. Adds `v_contracted_course_entitlements`, which answers "are we delivering what we sold". |

| 291 | `291_course_distribution_class_and_visibility_guard.sql` | **Paid content can no longer be given away by accident.** `courses.distribution_class` (`licensed` by default) plus a trigger that refuses `global` scope on licensed content, a recorded-exception table, `v_course_visibility_drift`, and a tier-1 platform monitor. Same shape as the navigation ownership guard, because that pattern works. |

**Two things worth carrying forward.**

A view over an RLS-protected table is a tenant-isolation hole unless it is
created with `security_invoker = on`. Postgres defaults to the view owner's
rights. Run the Supabase security advisor after adding any view here.

81 pre-existing functions still carry the default PUBLIC execute grant that 288
removed from these five. Deliberately not swept — that is its own decision,
not something to do quietly alongside a feature.

## Validation

Migrations 003–006 were validated by applying `001`→`00N` in sequence on a
throwaway PostgreSQL 16 instance (with a Supabase shim: an `auth.uid()` that
reads a session setting, plus `anon`/`authenticated` roles), including real
Row-Level-Security tests using `SET ROLE authenticated` to confirm cross-tenant
isolation (e.g. one operator cannot see another operator's private course).

Migration 008 was applied to the live project and its seed + policies verified
(five platform transport rows; `email_platform`, `email_alias_tenant` and
`email_logs_admin` policies present).

## Not yet written (later phases)

- **Tracking / SCORM** (Phases 5–6): `scorm_packages`, `course_attempts`,
  `scorm_tracking`, `native_progress`, `xapi_statements`. Deferred so they can
  be designed alongside the player/LRS runtime.
- **Voiceover** (Phase 8): `voiceover_assets`, `tenant_voice_profile`,
  `tenant_voiceover_usage` (ElevenLabs). Deferred pending the funding/metering
  decision.
- **Email runtime wiring**: a mailer manager that reads the enabled
  `email_integrations` row, decrypts its secret, configures the Laravel
  transport, and applies the current tenant's `tenant_email_aliases` identity at
  send time (plus writing `email_send_logs`). The schema + owner console are in
  place; this is the remaining runtime step.

See `../BespokeLMS-Global-Courses-Console-Proposal.md` for the full design.
