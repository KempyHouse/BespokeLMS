# BespokeLMS — Global Courses Console

### Research & design proposal for the Platform → Global Courses management console

**Prepared:** 23 July 2026 · **Status:** proposal for review (no code changes yet) · **Audience:** platform owner (Marcus Reed / Andrew)

---

## 1. Purpose and scope

Today the **Platform → Global Courses** page is a placeholder: a single card and a disabled *"Publish Course (coming soon)"* button. The `courses` table behind it is a flat mock catalogue (28 seeded rows, one row per course, a category, a price and a `catalog_status`). That is fine as a learner-facing browse list, but it cannot carry what you have described.

This document proposes turning that page into the **course management console for the entire BespokeLMS ecosystem** — the single place where every course, in every language, at every version, for every tenant, is created, reviewed, approved, versioned, narrated and governed.

The requirements you set, restated so we agree on them:

- **One central store** for all courses across the whole platform, plus operator-authored courses.
- **Version control** — courses are edited over time with a full history and the ability to roll back.
- **Language versions** — multiple locales per course (AI-assisted translation, then human review).
- **Tenant visibility controls** — which tenants can see each course.
- **Search, sort, filter, grouping** that stays usable at hundreds of courses.
- **Categorisation and tagging** at platform level, **overridable per tenant** (each tenant LMS may organise differently).
- **SCORM compliance for every course** — both natively authored courses and imported third-party packages.
- **Three native slide types** — image + text, video, and document-reading.
- **ElevenLabs voiceover** for accessibility, populating multiple locations, with learner data isolated per tenant.
- **An embedded planning tool** — the full course lifecycle: design, development, approval; one person writes, another approves; per-course review dates.

Following your answers to the scoping questions, the design assumes: **both native authoring and SCORM import** under one course record; **platform *and* operators can author**; and **AI-assisted-then-human-reviewed translations**.

This is a **proposal only**. Nothing in the database or the app has been changed. The intent is that you read it, we adjust the decisions you want to adjust, and only then do we build — in line with the project rule to review the architecture in full before implementing.

---

## 2. How this fits the system you already have

The console is an extension of the current architecture, not a new island. It reuses:

- **The organisations tree** (`organizations`, self-referencing: platform → operator → client → team). "Which tenant can see a course" and "who owns a course" both resolve against this tree, so a grant to a parent flows to its children.
- **The RBAC + RLS model** (`app_role`, the `SECURITY DEFINER` helpers `org_and_descendants`, `auth_org_id`, `is_admin`, `visible_profile_ids`). Every new table is tenant-scoped and protected the same way, so tenant isolation is enforced in the database, not just in Laravel.
- **The Supabase design-token layer** (migration 005/006, `design_tokens` + `brand_kits` + `brand_kit_tokens`, injected as CSS variables). The console is styled 100% from tokens — no raw hex, no arbitrary pixel values — exactly as the project standards require.
- **The reusable data-table component** (`components/data-table.blade.php`) with its search, filter selects, sortable columns, multi-select, bulk actions and pagination. The catalogue list is built on this, so it looks and behaves like the Tenants table already in the Platform workspace.
- **The existing `ai_integrations` / `ai_usage_logs` pattern** (owner-only, key encrypted server-side). ElevenLabs slots in as another provider-style integration with the same security posture.

The existing learning-content tables are **evolved, not thrown away**:

| Today | Becomes |
|---|---|
| `courses` (flat, one row = one course) | `courses` = the stable **identity/shell**; the editable content moves into `course_versions` and below. |
| `course_categories` | the **global** `categories` taxonomy (baseline, with per-tenant overrides layered on top). |
| `enrollments` | gains a `course_version_id` so a learner is **pinned** to the version they started. |
| `certificates`, `course_requirements` | kept; `certificates` gains an expiry/recert link to the review-date engine. |

Migrations are additive and declarative (new migration files, snake_case, ISO dates, RLS on every table), matching the Supabase/Postgres conventions already in use.

---

## 3. The console at a glance

What Platform → Global Courses becomes, as an information architecture:

**Catalogue view (landing).** A full-width, database-driven table of every course the signed-in owner is entitled to manage — built on the existing data-table. Columns: Title, Owner (Platform / operator name), Type (Native / SCORM / Mixed), Status (workflow state), Languages (locale chips), Current version, Category, Review due, Visibility, Updated. Toolbar: full-text search; facet filters (status, type, owner, category, language, standard, review-due); sort; grouping (by category or owner); saved views; bulk actions (publish, retire, reassign reviewer, re-tag, grant/revoke tenants). Cursor pagination so it stays fast at scale.

**Course workspace (drill-in).** Opening a course reveals a tabbed workspace, mirroring the tenant config-hub pattern you already built:

- **Overview** — identity, owner, current published version, quick status.
- **Content / Builder** — the version's modules → lessons → slides (or the imported SCORM package), with the slide editor for the three native types.
- **Versions** — version history, "what changed", publish, clone, rollback, pin policy.
- **Languages** — per-locale translation status, AI-draft, human-review, voiceover state.
- **Voiceover** — ElevenLabs voice per language, generate/regenerate, listen, usage.
- **Workflow / Planning** — the lifecycle board: state, assigned author/reviewer/approver, checklist, sign-offs, review date. *This is the "planning tool" you asked for.*
- **Taxonomy** — global categories/tags for the course.
- **Visibility** — which tenants can see it (global / allow-list / private), with the org-tree picker.
- **Tracking & standards** — SCORM/xAPI settings, completion/scoring rules, export SCORM package.

**Create flow.** The disabled button becomes **"+ New course"** with a choice at the top: *Author natively* (start from slides) or *Import SCORM package* (upload a `.zip`). Both create the same kind of course record; only the content type differs.

---

## 4. Core content model

The single most important modelling decision, and the one that keeps everything else sane, is to treat **editorial version** and **language variant** as two independent axes.

- A **course** is the stable identity — it never moves; everything hangs off it.
- A **course version** is one editorial revision (v1.0, v1.1, v2.0). It moves through the approval workflow, gets published, and is what a learner is pinned to. Published versions are **immutable snapshots**; editing creates a new draft.
- A **language variant** is a per-locale rendering of a version's text (English base, French, Welsh…). Variants can lag — English can be live while French is still in review — each with its own status.

```
course  (identity, owner, catalogue membership, visibility)
  └─ course_version  (draft / published / archived · semver · immutable once published)
       ├─ module      →  lesson  →  slide     (native content: 3 slide types)
       └─ scorm_package                        (imported content: a sibling type)

  content_translations  (entity, entity_id, locale, fields) — the language axis, spanning the above
```

**Why a `module` level even though small courses won't use it:** adding a hierarchy level later is a painful migration; leaving an always-present "Module 1" costs nothing and lets larger courses group lessons without a schema change.

**Slide types.** The three types (image+text, video, document-reading) are modelled as **one `slides` table** with a `type` column and a validated `jsonb` payload, rather than three separate tables. They share the same spine (id, lesson, position, title, type, timestamps) and differ only in a few payload fields, so reordering, counting, duplicating and workflow all work type-agnostically — and adding a fourth type later (e.g. a quiz) needs no migration. Fields you filter or sort on often (duration, video provider) are promoted to real columns; the rest stays in `jsonb`, validated in Laravel Form Requests and optionally by a Postgres JSON-schema check.

**SCORM is a sibling, not a slide.** An imported SCORM package is nothing like a slide at runtime (it has a manifest, a launch URL, its own JavaScript, its own tracking model). So a course version is **either** a set of native slides **or** a SCORM package (or a mix at module granularity) — SCORM lives in its own `scorm_packages` table, described next.

---

## 5. SCORM compliance and standards strategy

You said every course must be SCORM compliant, and you want both native authoring and third-party imports. Here is the recommended way to satisfy both, based on where the e-learning standards actually are in 2026.

### 5.1 Which standards to target

- **Import — SCORM 1.2 (primary) + SCORM 2004 4th Edition (secondary).** SCORM 1.2 is still the most widely produced export format from Articulate Storyline/Rise, Adobe Captivate, iSpring, etc. Supporting it is non-negotiable for ingesting third-party content; 2004 covers the minority that use multi-part sequencing. AICC is effectively dead — skip it unless a specific client demands it.
- **Native tracking + strategic direction — xAPI, structured with the cmi5 profile.** xAPI records any learning experience as *actor–verb–object* statements sent to a **Learning Record Store (LRS)**. On its own xAPI doesn't define how to package or launch a course; **cmi5 is the missing rulebook** layered on top (package, launch handshake, standard verbs: launched/initialized/completed/passed/failed/terminated). cmi5 gives you SCORM-style completion/score semantics with modern transport and far richer analytics — the right way to track natively-built courses and to future-proof the platform.
- **Native export — SCORM 1.2 package.** So an operator can take a course you built and load it into *any other* SCORM LMS.

In short: **imported courses play as SCORM; native courses are tracked via cmi5/xAPI and can be exported as SCORM.** Both report into one place, so "every course is SCORM/standards compliant" holds true across the board.

### 5.2 Playing imported SCORM packages

- **Unzip on upload**, don't serve from inside the zip. SCORM content references sibling files by relative path and expects ordinary HTTP GETs. Store the extracted tree in Supabase Storage, keep the original `.zip` for re-export/audit, and parse `imsmanifest.xml` at ingest to record the SCORM edition, launch `href` and SCO list.
- **Use the open-source `scorm-again` library** (MIT licence) as the run-time engine. It implements the SCORM 1.2 and 2004 JavaScript API that content expects to find (`window.API` / `window.API_1484_11`), and commits tracking data to a URL you control — perfect for persisting into Supabase. This is the piece you would otherwise spend months building.
- **Run untrusted content sandboxed and origin-isolated.** Third-party SCORM is arbitrary JavaScript. Host it on a **dedicated per-tenant content origin** (e.g. `content-{tenant}.bespoke-cdn…`), inside a sandboxed `<iframe>`, and bridge the SCORM API over `postMessage` using `scorm-again`'s cross-frame mode — so the content can track progress but can never read your app's DOM, cookies or another tenant's data. Serve assets through a Laravel/edge proxy that checks the learner's tenant + enrolment and applies a strict Content-Security-Policy; never public URLs.
- **Version-pin live attempts.** A new upload is a new immutable package version; learners mid-course stay on the version they started, so their bookmark/resume state (`suspend_data`) never corrupts.

### 5.3 Tracking native slide courses to the standard

Instrument the native slide player to emit **cmi5/xAPI statements to the LRS**: `launched`/`initialized` at start, per-slide progress, `completed` when the completion rule is met, `passed`/`failed` with a scaled score if the course is scored, `terminated` on exit. Keep a fast `native_progress` table for the UI; the LRS is the compliance system of record. A slide course defines its own completion/scoring rules — e.g. "all required slides engaged" for completion (a video watched to X%, a document scrolled to the end, a text slide shown for a minimum time), and an optional quiz/points score — which map cleanly onto both cmi5 (`completed` + `score.scaled`) and SCORM (`lesson_status` + `score`) on export.

### 5.4 The LRS

For a lean team already on Postgres, self-host a **Postgres-based LRS** (SQL LRS, Apache-2.0, runs on Postgres; Veracity is a low-cost alternative). Rustici's hosted **SCORM Cloud** is a good MVP shortcut, but its per-registration pricing erodes margin for a white-label reseller with many learners, so it's a fallback rather than the foundation. (One item to re-verify at build time: Learning Locker's current open-source licensing has shifted commercially — prefer SQL LRS / Veracity.)

### 5.5 Learner tracking tables (tenant-isolated)

Every row carries `tenant_id` (or resolves via the enrolment's org) and is RLS-protected, so one tenant's learner progress is invisible to another:

- `enrollments` (existing, extended) — add `course_version_id` (the pin), `certificate_expires_at`.
- `course_attempts` — one per registration: `enrollment_id`, `attempt_no`, `registration_uuid` (also the cmi5 registration), start/complete timestamps.
- `scorm_tracking` — the CMI data model per attempt/SCO: `completion_status`, `success_status`, `score_raw/min/max/scaled`, `total_time`, `location` (bookmark), `suspend_data`, `entry`, `exit`.
- `native_progress` — per attempt/slide: engaged, view seconds, points, completed_at.
- `xapi_statements` — the LRS store (or a mirror) keyed by tenant + registration for analytics.

---

## 6. Versioning and version control

The mature, low-risk pattern (used by Contentful, Sanity, Strapi, AEM) is **copy-on-publish immutable snapshots**:

- A **draft** version is freely editable.
- **Publishing freezes it** — content becomes immutable. Further edits clone the last published version into a new draft, which becomes the next version when published.
- **Archived** versions are read-only, hidden from new enrolment, retained for audit and for learners still pinned to them.

**Version numbers** are semantic-ish and author-assigned at publish, with a simple rule: a **major** bump (2.0) means the content changed enough to warrant re-taking / re-certification; a **minor** bump (1.3) is a typo/asset fix with no learning impact. Store both a monotonic internal `version_no` (for ordering/FKs) and a display `semver`.

**Enrolments are pinned** to `course_version_id`, so a learner mid-course keeps their version even after a new one publishes. On a new *major* version the default is safe: in-flight learners finish the old version, only new enrolments get the new one; force-migration (reset progress + require re-cert) is an explicit opt-in per course.

**History and rollback.** An append-only `content_audit_log` (actor, entity, action, before/after diff as `jsonb`, timestamp) answers "who changed what". Because published versions are immutable, rollback is non-destructive: *"restore version N as a new draft"* rather than a risky revert. A short author-written `changelog` per version feeds a learner-facing "course updated" notice.

---

## 7. The planning tool — editorial workflow, roles, approval, review dates

This is the heart of your request: *"one team member writes the course, another approves, and each course may include review dates."* It's modelled as an explicit, **configurable workflow state machine** plus per-course role assignments, a sign-off checklist, and a review-date engine.

### 7.1 Lifecycle state machine

Default lifecycle (states and transitions are **data-driven rows**, so a tenant or the platform can insert extra steps like "Legal review" or "SME sign-off" without code changes):

```
Draft ──submit──▶ In Review ──approve──▶ Approved ──publish──▶ Published
  ▲                    │                                            │
  └───request changes──┘                                     review-due (date-triggered)
                                                                    │
                                                             Review Due ──re-approve──▶ Published
                                                                    └──retire──▶ Retired / Archived
```

Every transition records who did it, when, and a comment — that's your workflow history.

### 7.2 Separation of duties

"One writes, another approves" is enforced **at the transition level**: the person who submitted a version cannot be the one who approves it (`approver_id != author_id`), plus a capability check on the role. This is a guard on the `approve` transition, on by default, configurable if a tenant wants to relax it.

### 7.3 Roles assigned per course

Global roles set a baseline, but **author / reviewer / approver are assigned per course (or per version)** via a `course_assignments` table, so different courses have different subject-matter experts and approvers. This works for both platform-authored and operator-authored courses.

### 7.4 Checklist and sign-off gate

Each version has a **checklist** of required items (e.g. "accessibility checked", "translations complete", "SME approved", "voiceover generated") that must be ticked before `approve → publish` is permitted. Sign-offs are immutable rows (who, what, when) — the audit trail for regulated training.

### 7.5 Review dates and recertification

Each published version (or course) carries a `review_interval` (e.g. 12 months) and a computed `review_due_at`. A scheduled job (Laravel scheduler / Supabase cron) flips content to **Review Due** and notifies the assigned reviewer/approver when the date passes; separately, `certificates.expires_at` drives learner recertification reminders before a certificate lapses. Content review (is the material still correct?) and learner recert (does this person need to re-take it?) are two different clocks, both handled.

### 7.6 Tables behind the planning tool

`workflow_states`, `workflow_transitions` (config; global default + per-tenant overrides), `course_workflow_state` (current state per version), `course_workflow_history` (every transition), `course_assignments` (user × course × role), `course_reviews` / `course_approvals` (decisions + sign-offs), `review_schedule` (interval, due, last reviewed, next reminder), `workflow_checklist_items` + `workflow_checklist_results` (the gate).

The **Workflow / Planning tab** renders this as a lifecycle board with the current state, the assigned people, the checklist, the sign-off history and the review date — a genuine editorial planning surface, not just a status flag.

---

## 8. Taxonomy and tagging with tenant override

You noted categorisation may differ per tenant, with some tagging at BespokeLMS level and the ability to override at tenant level. The pattern is a **global baseline + per-tenant overlay** — the global taxonomy stays clean and updatable; every tenant edit lands in overlay tables and is resolved with `COALESCE(tenant override, global value)`.

Three composable mechanisms:

1. **Category remap / rename / hide** — `tenant_category_overrides` maps a global category to a tenant's own label, parent or sort order, or hides it. A tenant sees "HSE" where the platform says "Health & Safety", nested their way, without forking the taxonomy.
2. **Tenant-local tags** — `tenant_tags` lets a tenant add private tags alongside global ones; the course↔tag join carries a nullable `tenant_id` (`NULL` = global tag, set = tenant-private).
3. **Per-tenant course metadata overrides** — `tenant_course_overrides` (override title, summary, category, custom fields) so a tenant can re-badge a global course for their audience.

The existing `course_categories` table becomes the global `categories` baseline; the overlays are new. Categorisation composes *after* visibility: a tenant only ever tags/categorises courses it is entitled to see.

---

## 9. Tenant visibility and entitlement

"Which tenant can see each course" is modelled **explicitly**, not inferred:

- **`course_visibility.scope`** per course: `global` (all tenants — the Global Catalogue default), `allowlist` (only listed tenants), or `private` (owning tenant only — operator-authored courses). A `denylist` ("everyone except X") is available if a real need appears, but allow-list + global covers most cases and is easier to reason about, so it's the default.
- **`course_entitlements`** — rows of (course, tenant node, granted/revoked, licence terms, seat cap, valid dates) for allow-list and for commercially licensing premium global courses to specific operators.

Because tenancy is an **org tree**, entitlements are stored against a node and **inherit down the subtree** (a grant to a reseller flows to its client schools unless a child-level revoke overrides). Effective visibility resolves with a recursive CTE over the org tree plus the entitlement rows — and, critically, is enforced with **Postgres RLS** so a query bug can never leak another operator's private courses. Operator-private courses stay isolated because their default scope is `private` and only the owning node appears in entitlements.

This is exactly what makes the page's tagline — *"Publish system courses that cascade to every tenant"* — real: a `global` course cascades automatically; anything narrower is an explicit, auditable grant.

---

## 10. ElevenLabs voiceover integration

You want AI voiceover for global accessibility, populating multiple locations, with student data isolated per tenant. Here is the recommended architecture.

**Model.** Use **`eleven_multilingual_v2`** for baked course narration — it's ElevenLabs' e-learning-tuned model, 29 languages, high quality, generous 10,000-character-per-request limit. (Flash/Turbo are cheaper realtime models but lower fidelity; only relevant if you ever narrate on the fly.)

**Pre-generate at publish/approve, don't synthesize on the fly.** For an LMS this is decisively better: you pay **once per unique text+voice+language+settings** and serve free thereafter; playback is instant; and you avoid ElevenLabs' low account-wide concurrency limit under live load. Generation runs as background Laravel queue jobs that respect a global concurrency semaphore, dispatched only **after** a locale's translation is human-approved (so you never pay to narrate text that will still change).

**Cache by content hash to avoid re-billing.** Key each audio asset by `sha256(normalized_text + voice_id + model_id + language_code + voice_settings + seed)`. Before calling the API, look up the hash — a hit means no API call and no charge. Editing one slide invalidates only that slide's audio; everything else is reused. This makes republishing and translated variants cheap.

**Storage and isolation.** Private Supabase Storage bucket, path-scoped per tenant: `voiceover/{tenant_id}/{course_id}/{locale}/{content_hash}.mp3`, RLS-isolated, served via short-lived signed URLs — so audio, like all learner-facing data, can't cross tenants.

**Per-tenant metering (essential).** ElevenLabs bills **one shared credit pool** with no native per-tenant separation. So the platform must meter it: count characters server-side *before* each call, write them to a `tenant_voiceover_usage` ledger, and enforce a monthly cap per tenant (queue or reject on breach). This stops one white-label operator draining the shared budget, and lets you show each operator their usage. The API key stays server-side only, in the same encrypted pattern as `ai_integrations`.

**White-label voice.** A `tenant_voice_profile` (tenant, locale, voice_id, model_id, settings, pronunciation dictionary) lets each operator choose their **brand voice**, per language, with a fallback chain (tenant+locale → tenant default → platform default). Because voice/settings feed the content hash, switching a brand voice cleanly regenerates only that tenant's affected audio.

**"Number of locations" it populates.** One `voiceover_assets` table (tenant, course, slide, locale, content_hash, voice/model/settings, storage_path, duration, character_count, status, timestamps) is the single source; it surfaces in the slide player, the course workspace's Voiceover tab, the accessibility/UDL layer, and — via `/with-timestamps` word timings — synchronized captions/transcripts.

**Accessibility framing.** AI voiceover is an **enhancement, not a WCAG conformance mechanism.** WCAG 2.2 AA is met by the underlying page — semantic HTML, headings, landmarks, alt text, focus management, keyboard operability, and **real captions/transcripts for video slides** (a separate obligation). Narration must be user-initiated, pausable, with visible controls, and never auto-play over a screen reader. Stored word-timing data gives synchronized caption highlighting and a text alternative — a strong universal-design feature that complements, rather than substitutes for, accessible markup.

---

## 11. Search, sort, filter and grouping at scale

Hundreds (even low thousands) of courses is small for Postgres — correct indexing matters more than heavy machinery, so **no Elasticsearch is needed**.

- **Full-text search** via a stored `tsvector` column (title + summary + tags, weighted) with a **GIN index**, ranked with `ts_rank`.
- **Fuzzy / partial / typo-tolerant search** via the **`pg_trgm`** extension with a trigram index, complementing full-text for short tokens and "starts-with".
- **Facet filters** — btree indexes on status, category, owner/tenant, locale, standard; a GIN index on the tags join; composite `(tenant_id, status)` for the common access path. Facet counts are cheap `GROUP BY` at this scale.
- **Grouping** by category or owner; **saved views** persist a filter+sort combo per user (e.g. "My review-due courses", "Unpublished global drafts") — the `saved_views` table already exists and extends naturally.
- **Bulk actions** and **cursor (keyset) pagination** — not `OFFSET`, which degrades past a few hundred rows.
- **Multi-locale search** indexes the translations side-table per locale, so a search finds a course by its French title too.

All of this is surfaced through the existing data-table component, so the catalogue matches the Tenants table's look and interactions.

---

## 12. Proposed database schema (design sketch)

New and evolved tables, grouped by concern. This is a design sketch (key columns, not full DDL); the actual migration would be declarative, snake_case, timestamptz, RLS-on-every-table, matching the existing conventions. Existing tables are marked *(existing)*.

**Content model**

- `courses` *(existing, refactored)* — `id`, `owner_org_id` (null = platform), `slug`, `title`, `current_published_version_id`, `type` (native/scorm/mixed), `created_by`, timestamps.
- `course_versions` — `id`, `course_id`, `version_no` (int), `semver`, `status` (draft/published/archived), `published_at/by`, `changelog`, `review_interval`, `review_due_at`, `is_scorm`.
- `modules` — `id`, `course_version_id`, `title`, `position`.
- `lessons` — `id`, `module_id`, `title`, `position`.
- `slides` — `id`, `lesson_id`, `position`, `type` (image_text/video/document), `payload` jsonb, `is_required`, `completion_rule`, `base_locale`.
- `scorm_packages` — `id`, `course_version_id`, `module_id` (nullable), `scorm_version`, `manifest_ref`, `launch_url`, `storage_path`, `content_hash`, `imported_at`.
- `content_translations` — `id`, `entity_type`, `entity_id`, `locale`, `fields` jsonb, `variant_status` (missing/draft/reviewed/published).

**Versioning, tracking & audit**

- `enrollments` *(existing, extended)* — add `course_version_id`, `certificate_expires_at`.
- `course_attempts` — `id`, `enrollment_id`, `attempt_no`, `registration_uuid`, `started_at`, `completed_at`.
- `scorm_tracking` — `id`, `attempt_id`, `sco_id`, `completion_status`, `success_status`, `score_raw/min/max/scaled`, `total_time`, `location`, `suspend_data`, `entry`, `exit`.
- `native_progress` — `id`, `attempt_id`, `slide_id`, `engaged`, `view_seconds`, `points`, `completed_at`.
- `xapi_statements` — LRS store / mirror: `id`, `organization_id`, `registration_uuid`, `verb`, `object_id`, `result` jsonb, `stored_at`.
- `content_audit_log` — `id`, `actor_id`, `entity_type`, `entity_id`, `action`, `diff` jsonb, `at`.

**Workflow / planning**

- `workflow_states` — `id`, `organization_id` (null = global), `key`, `label`, `is_terminal`, `sort`.
- `workflow_transitions` — `id`, `from_state_id`, `to_state_id`, `action`, `requires_distinct_actor`, `required_capability`.
- `course_workflow_state` — `course_version_id`, `state_id`, `entered_at`, `entered_by`.
- `course_workflow_history` — `id`, `course_version_id`, `from_state_id`, `to_state_id`, `actor_id`, `comment`, `at`.
- `course_assignments` — `id`, `course_id`, `user_id`, `role` (author/reviewer/approver).
- `course_reviews` / `course_approvals` — `id`, `course_version_id`, `actor_id`, `decision`, `comment`, `signed_at`.
- `review_schedule` — `course_id`, `review_interval`, `last_reviewed_at`, `review_due_at`, `next_reminder_at`.
- `workflow_checklist_items` + `workflow_checklist_results` — the sign-off gate.

**Taxonomy (global + tenant overlay)**

- `categories` *(from existing `course_categories`)* — `id`, `parent_id`, `key`, `label`.
- `tags` — `id`, `key`, `label`.
- `tenant_category_overrides` — `organization_id`, `category_id`, `override_label`, `override_parent_id`, `hidden`, `sort_order`.
- `tenant_tags` — `id`, `organization_id`, `label`.
- `course_categories` / `course_tags` (joins) — `course_id`, `category_id`/`tag_id`, `organization_id` (null = global).
- `tenant_course_overrides` — `organization_id`, `course_id`, `override_title`, `override_summary`, `override_category_id`, `custom` jsonb.

**Visibility / entitlement**

- `course_visibility` — `course_id`, `scope` (global/allowlist/private/denylist).
- `course_entitlements` — `id`, `course_id`, `org_node_id`, `state` (granted/revoked), `license_terms` jsonb, `seat_cap`, `valid_from/until`.

**Voiceover**

- `tenant_voice_profile` — `organization_id`, `locale`, `voice_id`, `model_id`, `voice_settings` jsonb, `pronunciation_dictionary_id`.
- `voiceover_assets` — `id`, `organization_id`, `course_id`, `slide_id`, `locale`, `content_hash` (unique), `source_text_ref`, `voice_id`, `model_id`, `voice_settings` jsonb, `seed`, `storage_path`, `duration_ms`, `character_count`, `timestamps_json`, `status`, `elevenlabs_request_id`, `generated_at`.
- `tenant_voiceover_usage` — `organization_id`, `period`, `characters_used`, `credits_used`, `cap`.
- `ai_integrations` *(existing)* — add an ElevenLabs provider row (key encrypted server-side).

**Search** — add `search_vector tsvector` (+ GIN) to `courses`; enable `pg_trgm`; btree/GIN indexes as in §11; extend `saved_views` *(existing)*.

---

## 13. Alignment with the project standards

The design was shaped to fit the standards in the project instructions:

- **Multi-tenant, white-label, strict isolation** — every table is tenant-scoped and RLS-protected against the org tree; voiceout, tracking and content all isolate per tenant; branding/voice are per-tenant overridable.
- **Database-driven, no mock/placeholder data** — the console is powered entirely by real schema-driven data and application logic; the current 28-row mock catalogue is migrated into the real version/translation model, not hard-coded.
- **Design tokens only** — the console UI uses the Supabase-backed token layer; no raw hex, no arbitrary pixel values; new UI values become tokens first.
- **Accessibility as a core requirement** — WCAG 2.2 AA baseline (semantic markup, keyboard, contrast, captions), with AI voiceover as an additive UDL enhancement, not a substitute.
- **Standards & tooling** — Laravel best practice (thin controllers, Form Requests, Eloquent-first, RESTful), PSR-12 / Pint; Supabase/Postgres conventions (snake_case, timestamptz, declarative RLS migrations); secrets server-side only.
- **Responsive, mobile-first** — the catalogue and workspace adapt across breakpoints; the *slide builder* and SCORM import are desktop-appropriate tasks and should cleanly direct small screens to desktop rather than degrade (matching the existing matrix desktop-gate approach).

---

## 14. Suggested delivery sequence

Built in dependency order so each phase is usable and de-risks the next:

1. **Content model + two-axis versioning** — `courses`/`course_versions`/`modules`/`lessons`/`slides`/`content_translations`, migrate the 28 seeded courses into it. Foundational.
2. **Visibility / entitlement + RLS** — before any real multi-tenant course data flows, lock down who sees what.
3. **Catalogue console UI** — the data-table list with search/filter/sort/grouping/saved-views/bulk-actions, plus the course workspace shell.
4. **Workflow / planning tool** — state machine, assignments, checklist, review-date engine. Delivers the planning surface you asked for.
5. **Native slide builder + player** — the three slide types, completion rules, cmi5/xAPI tracking to the LRS.
6. **SCORM import + player** — `scorm-again`, sandboxed origin, storage, tracking; then SCORM export of native courses.
7. **Taxonomy overlay** — global categories/tags + per-tenant overrides.
8. **ElevenLabs voiceover** — voice profiles, generation queue, caching, metering, captions.
9. **Analytics on the LRS** — usage & completion reporting across native and imported content.

Phases 1–4 stand up the *management* console (what the page is fundamentally about); 5–6 add the *authoring/playback* engine; 7–9 add polish, accessibility and insight.

---

## 15. Decisions to confirm and things to re-verify

A few points worth your steer before build, and a couple to re-check at implementation time:

**For you to decide:**

- **Operator authoring depth** — can operators build fully native courses, or (initially) only import SCORM and manage/tag global courses? This affects how much of the builder needs tenant-facing permissions in phase 1.
- **Approval strictness by default** — enforce "author ≠ approver" platform-wide, or let each tenant opt in? (Recommended: on by default, configurable.)
- **Version-change policy default** — on a major version, finish-then-switch for in-flight learners (recommended) vs force re-cert.
- **Voiceover funding model** — platform-funded with per-tenant caps, or operators bring/pay for their own ElevenLabs allotment? Drives the metering/billing UI.
- **LRS choice** — self-host SQL LRS (recommended, Postgres-native) vs start on SCORM Cloud for speed.

**To re-verify at build time** (things that move): ElevenLabs' exact pricing/credit tiers and concurrency limits, and the Dec-2026 sunset of their default voices; the current open-source licensing of Learning Locker (prefer SQL LRS / Veracity); and SCORM 2004 sequencing coverage in `scorm-again` for any unusually complex imported packages.

---

*This proposal is deliberately implementation-ready but not implemented. On your say-so — and after we settle the decisions in §15 — the natural next step is Phase 1: the migration for the content model + versioning, applied to the BespokeLMS Supabase project, with the 28 seeded courses lifted into it.*
