# BespokeLMS — database migrations

Declarative SQL migrations for the BespokeLMS Supabase/Postgres project
(`pqmdtqsscyltykgcwwus`, region eu-west-1). Numbered; **apply in order**.

## How to apply

These are run **manually in the Supabase SQL Editor** (the Supabase MCP
connector can't currently reach the BespokeLMS org, so migrations are not
applied automatically). Open each file, paste it into a new SQL Editor query,
run it, then move to the next number. Each migration is additive and safe to
run once on top of the previous ones.

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

Apply order for the new work: **003 → 004 → 005 → 006** (001 and 002 are already live).

## Validation

Migrations 003–006 were validated by applying `001`→`00N` in sequence on a
throwaway PostgreSQL 16 instance (with a Supabase shim: an `auth.uid()` that
reads a session setting, plus `anon`/`authenticated` roles), including real
Row-Level-Security tests using `SET ROLE authenticated` to confirm cross-tenant
isolation (e.g. one operator cannot see another operator's private course).

## Not yet written (later phases)

- **Tracking / SCORM** (Phases 5–6): `scorm_packages`, `course_attempts`,
  `scorm_tracking`, `native_progress`, `xapi_statements`. Deferred so they can
  be designed alongside the player/LRS runtime.
- **Voiceover** (Phase 8): `voiceover_assets`, `tenant_voice_profile`,
  `tenant_voiceover_usage` (ElevenLabs). Deferred pending the funding/metering
  decision.

See `../BespokeLMS-Global-Courses-Console-Proposal.md` for the full design.
