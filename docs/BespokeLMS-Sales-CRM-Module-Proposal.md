# BespokeLMS — Sales CRM Module: Analysis & Implementation Plan

**Date:** 25 July 2026 · **Status:** Proposal for review — nothing applied
**Scope:** Core CRM (accounts, contacts, timeline, documents, pipeline, segments), tenancy & GDPR architecture, Freshsales migration, menu-builder integration. Written against the **live** Supabase schema (75 public tables, migrations through `..._semantic_email_templates_027`) and the `bespokelms-app` Laravel codebase as of today.

---

## 1. Where the platform stands (what the CRM must fit into)

The analysis below is grounded in the live database and code, not the mock-up:

**Tenancy.** `organizations` is a self-referencing tree (`platform` → `operator` [reseller / inhouse / own_brand] → `client`), with RLS built on SECURITY DEFINER helpers (`auth_org_id()`, `org_and_descendants()`, `is_platform_owner()`). Most existing policies grant **subtree** visibility — the platform owner sees everything operational, an operator sees its clients. This is correct for LMS operations and **must not be copied for CRM data** (see Challenge C2).

**Application patterns.** The Laravel app is session-authed against Supabase Auth, with a `Reads*`/`Writes*` contract-per-feature pattern (`SupabaseOrganizations`, `SupabaseCourses`, …) over PostgREST. Owner-area routes sit behind the `platform.owner` 404-middleware; sensitive writes add `platform.sudo` step-up re-auth; every write audits via `WritesAuditLog`. Reads for owner consoles use the **service-role key** (bypasses RLS), with the middleware as the authorisation boundary. The CRM has to be more careful than this (C2).

**Navigation.** Fully data-driven and live: code-first `RouteRegistry` (`nav:sync-registry`) → `route_registry` → managed `nav_menus` / versions / items / role-visibility, rendered by `NavigationResolver`. `ops.sales-crm` already exists in the registry as `status: planned`, `scope: operations` — that is the "Soon" pill in your screenshot. The registry supports `feature_flag`, `tenant_subtypes`, `internal_only`; the builder supports groups, labels, icons, role visibility, publish/rollback.

**Adjacent machinery the CRM should reuse, not duplicate:**

| Existing asset | Reuse in CRM |
|---|---|
| Board engine (mig. 008): `boards → board_stages → work_items`, subject type **`deal`** already anticipated | Kanban UI component + post-sale delivery tasks linked to a won deal |
| `email_integrations` + `tenant_email_aliases` + `TenantMailer` + `BrandedEmailRenderer` | All CRM outbound email goes through this transport, branded per tenant |
| `outbound_templates` + Communication menu group (system emails live; SMS/WhatsApp/marketing = coming soon) | Timeline ingestion contract (§8) so every channel writes CRM activities the same way |
| `audit_log`, `platform.sudo`, `WritesAuditLog` | CRM config changes, imports, erasures, exports |
| `<x-data-table>` shell, design tokens, `pg_trgm` (already installed) | List pages, styling, duplicate detection |
| `feature_flags` (platform-global) | **Not sufficient** for per-tenant module enablement — see §5 |

---

## 2. Challenging the brief

You asked me to challenge everything. These are the points where I'd push back or sharpen the requirement, with a recommendation for each.

### C1. "Accounts … might become tenants" — do not make organizations your CRM accounts
The tempting shortcut is to treat `organizations` as the accounts table (March Foods is already both). Don't. `organizations` is **operational tenancy** — RLS anchors, brand kits, enrolment scoping hang off it. CRM accounts are **relationship records**: most will never be tenants, they churn, get merged, get archived, get erased under GDPR. Erasing or merging a row that is also an RLS anchor would be catastrophic.
**Recommendation:** separate `crm_accounts` with a nullable `organization_id` link. "Convert to tenant" is an explicit promotion flow that creates/links the organization and records the link — March Foods becomes one account row *linked to* its existing operator org, carrying the in-house-LMS opportunity. The link is also what powers auto-detection of contacts who become platform users (§9).

### C2. Tenant isolation must be *stricter* than the rest of the platform — and that includes you
Everything else in BespokeLMS gives the platform owner subtree visibility. For CRM data that is exactly wrong: **Turner Price's pipeline is Turner Price's controller data, and BespokeLMS must not be able to read it** — you said this yourself, and the schema must enforce it, not the UI. Two consequences:

1. **RLS is org-exact, never subtree.** CRM policies compare `owning_organization_id = auth_org_id()` directly. No `org_and_descendants()`, and `is_platform_owner()` grants access only to rows owned by the BespokeLMS org itself.
2. **The service-role habit is a hazard here.** Existing owner consoles read with the service-role key and rely on route middleware. If a future CRM query forgets a `owning_organization_id` filter, service-role reads would leak another tenant's pipeline. **Recommendation:** CRM readers/writers take the owning org from the *authenticated user's profile* (never from request input), apply it to every PostgREST call, and keep RLS as defence-in-depth. Add a CI-level convention test: every `SupabaseCrm*` class must go through a single `CrmScope` value object that carries the org id.

### C3. Communicating with a tenant's clients (B2B2C) — your instinct is right; go further
You proposed: BespokeLMS cannot see Turner Price's client communications through the CRM, but can see the tenant relationship through the Tenants module. Correct, and worth stating *why*, because it dictates the design: for Turner Price's CRM data, **Turner Price is the data controller and BespokeLMS (the company) is a processor**. Using data you host as processor to prospect those same schools yourself would be a purpose-limitation breach (UK GDPR Art. 5(1)(b)) — and commercially it's channel conflict with your own reseller.

So there are only two legitimate ways BespokeLMS communicates with All Saints' Primary:

- **Operational / service communications** (platform notices, incident emails, system emails) — sent *as processor on the tenant's behalf*, through the existing outbound/system-email machinery, branded as the tenant. These are not CRM activities in BespokeLMS's CRM and never create BespokeLMS CRM contacts.
- **An independent relationship** — the school approaches BespokeLMS directly, or you prospect it from public sources. Then it becomes a *new* account in **BespokeLMS's own CRM** with its own provenance and lawful basis recorded. Nothing is copied from Turner Price's tenant data, even though the same school exists there. The `source`/`source_detail` fields (§4) make this provable.

**Recommendation:** encode this as a hard rule: *CRM records never reference another tenant's CRM records, and conversion from operational data (learner profiles, tenant client lists) into CRM contacts is only allowed within your own controller boundary* (e.g. BespokeLMS may create a contact for Turner Price's buyer — Turner Price is *your* customer — but not for Turner Price's schools).

### C4. Duplicate people across tenants are a feature, not a bug
The same person may exist in BespokeLMS's CRM and in Turner Price's CRM. Do **not** build cross-tenant deduplication, shared person records, or global email uniqueness — each tenant is a separate controller and merging would itself be a data-sharing breach. Dedup (via `pg_trgm` + email match) operates *within* one owning org only.

### C5. Drop the separate "Leads" object — use lifecycle stages
Freshsales models Leads as a separate object that "converts" into contact+account; HubSpot uses one contact/account record with a **lifecycle stage**. The HubSpot model is simpler, avoids painful convert-time data copying, and matches your statement that "accounts and/or contacts may not be clients". **Recommendation:** one `crm_lifecycle_stage` enum (`lead → marketing_qualified → sales_qualified → opportunity → customer → churned`, plus `partner`) on both accounts and contacts. The **Leads / Prospects** menu item in your screenshot stays — as a saved, filtered view of contacts/accounts, not a table. If a future Freshsales sync truly needs a Leads object, map it at the sync layer.

### C6. Deals: native CRM tables, not the board engine
Migration 008's board engine already anticipated `deal` as a work-item subject, so it's tempting to model opportunities as work items. I recommend against: deals need value, currency, probability, forecast category, expected close, won/lost semantics — none of which belong on generic `work_items`, and pipeline reporting (weighted forecast, velocity) would fight the generic schema. **Recommendation:** first-class `crm_pipelines / crm_pipeline_stages / crm_deals` (stage colours as design-token *keys*, exactly like `board_stages` does), reuse the **Kanban UI component** when it's built, and keep the board engine's `deal` subject for what it's good at — post-sale onboarding/delivery tasks linked to a won deal.

### C7. Don't retrofit the timeline onto `email_send_logs`
`email_send_logs` deliberately stores `to_domain` only — no PII — and that design should survive. The CRM timeline is the opposite: it is *deliberately* personal data, scoped, retained and erasable per controller. **Recommendation:** `crm_activities` is its own store; channel modules *push* activity rows for known contacts (§8) rather than the CRM joining onto delivery logs.

### C8. "Link to all sections within the communication module" — define a contract, not point integrations
Most Communication destinations are `coming_soon` (Transactional, Marketing, SMS, WhatsApp, Social, Score, Logs). Integrating the CRM with each one ad hoc would create N bespoke couplings. **Recommendation:** define one **activity-ingestion contract** now — `RecordsCrmActivity::record(CrmScope, type, direction, refs, payload)` — that every current and future channel calls when a message involves a known CRM contact (matched by recipient within the sending org's CRM only). System emails wire in immediately; each future channel gets timeline integration for free on launch.

### C9. "Not all tenants need the CRM" — this forces a per-tenant module layer that doesn't exist yet
`feature_flags` is platform-global; `route_registry.feature_flag` gates globally too. Nothing today can say "Sales CRM is on for BespokeLMS and Turner Price but off for March Foods". This is the first of several Operations modules with the same need (Support Desk, Marketing, Live Chat…), so build it once: **`tenant_modules`** (§4) + an `EnsureModuleEnabled` middleware + a navigation-visibility dimension (§7). Tenants who bought the LMS to train their own staff simply never get the module enabled; resellers can have it enabled or later choose third-party sync instead.

### C10. Third-party sync later — but identity/provenance must be designed now
Retrofitting sync onto records with no external identity is painful. Cheap now, expensive later: `crm_external_links` (entity ↔ provider ↔ external id), `source`/`source_detail` on every record, `updated_at` everywhere, and soft-delete (`archived_at`) semantics so a future sync engine can diff. The Freshsales *import* (§10) uses the same table, so batch #1 of "sync" is effectively built by the migration work.

### C11. "Manage all comms from one application" — true for your controller boundary only
Achievable for everything where BespokeLMS (or Teach HQ Ltd's own brands — TeachHQ, FoodComplianceHQ) is the controller: prospects, tenants' buyers, partners. Each own-brand operator is its own tenant with its own CRM space, so "one application" = one UI over several strictly separated CRM scopes you legitimately control — with the workspace/tenant switcher deciding which scope you're acting in. What it can never mean is one merged address book across the estate.

---

## 3. Target information architecture

Person-centric contacts, org-centric accounts, many-to-many between them (one person at several companies; several people per account), everything hanging off an **owning organization** (the tenant whose CRM it is):

```
organizations (existing) ──┐ (nullable promotion link)
                           ▼
        crm_accounts ◄──── crm_account_contacts ────► crm_contacts ──► profiles (existing,
             │                (role, primary, dates)        │           nullable auto-link)
             │                                              │
             ├────────► crm_deals ◄── crm_deal_contacts ────┤
             │            │  (pipeline_id, stage_id)        │
             ├────────► crm_activities (timeline) ◄─────────┤
             ├────────► crm_documents ◄─────────────────────┤
             │                                              │
             └────────► crm_external_links   crm_segments ◄─┘ (static now, dynamic later)
```

A contact with no account is valid (B2C). A deal with no account but a contact is valid (B2C sale). Activities and documents require at least one anchor (account, contact or deal) — enforced by CHECK constraints.

---

## 4. Proposed schema — migration series 028+

All Supabase/Postgres conventions as per project standards (snake_case, lowercase keywords, RLS on every table, `security_invoker` views, token keys not hex values). Sketch, not final DDL:

**`028_bespokelms_tenant_modules`** *(platform infrastructure, not CRM-specific)*
- `tenant_modules` — `organization_id FK`, `module_key text` (`sales_crm`, later `support_desk`, …), `enabled bool`, `enabled_by/at`, `settings jsonb` (per-module config: CRM retention months, default currency GBP, fiscal year…). Unique `(organization_id, module_key)`. RLS: owner manages all; tenant admins read their own row.
- Seed: `sales_crm` enabled **only** for the BespokeLMS platform org.

**`029_bespokelms_crm_core`**
- Enums: `crm_lifecycle_stage` (C5); `crm_activity_type` (`note, call, email, meeting, task, sms, whatsapp, document, system`); `crm_activity_direction` (`inbound, outbound, internal`); `crm_deal_status` (`open, won, lost`); `crm_record_source` (`manual, import_freshsales, import_csv, web_form, auto_link, api, sync`).
- `crm_accounts` — `owning_organization_id FK` (the isolation anchor on **every** CRM table), `organization_id FK null` (promotion link, C1), `name`, `legal_name`, `website_domain`, `industry`, `employee_band`, `lifecycle_stage`, `owner_profile_id` (account owner — a *profile in the owning org*), `source`, `source_detail text`, `phone`, `address_*` (business address), `description`, `archived_at`, timestamps, `created_by`.
- `crm_contacts` — owning org, `first_name/last_name`, `email` (`citext`), `phone`, `mobile`, `job_title`, `lifecycle_stage`, `owner_profile_id`, `source` + `source_detail`, **`profile_id FK null` + `profile_linked_at` + `profile_link_method` (`auto_email_match | manual`)** (§9), `do_not_contact bool` (hard stop, distinct from consent), `archived_at`, timestamps. Partial unique index `(owning_organization_id, email) where archived_at is null` — with a merge flow rather than a hard failure on import collisions.
- `crm_account_contacts` — account, contact, `role_at_account`, `is_primary`, `started_on/ended_on` (people move; history preserved). Unique `(account_id, contact_id)`; CHECK both sides share `owning_organization_id`.
- `crm_activities` — owning org, `activity_type`, `direction null`, `subject`, `body`, `happened_at`, `due_at/completed_at` (tasks), `actor_profile_id`, `account_id/contact_id/deal_id` (nullable FKs, CHECK ≥ 1 anchor), `channel_refs jsonb` (message ids, provider ids — no bodies duplicated), `source`, timestamps. Indexes: `(owning_organization_id, happened_at desc)`, per-anchor.
- `crm_documents` — owning org, `storage_path` in a new **private `crm-documents` bucket**, path prefix `{owning_organization_id}/…` with storage RLS on the prefix (same hardening pattern as `avatars`/`branding` buckets), `file_name`, `mime_type`, `byte_size`, anchors + CHECK, `uploaded_by`, timestamps.
- RLS helper `crm_org_access(org uuid)` — true iff the caller's profile is in **exactly** that org, with an admin-tier role, and `tenant_modules` says `sales_crm` is enabled. Used by every policy. Explicitly **no** subtree traversal (C2).

**`030_bespokelms_crm_pipeline`**
- `crm_pipelines` (owning org, name, `is_default`), `crm_pipeline_stages` (key, label, sort, `win_probability`, `is_won/is_lost`, `colour_bg_token/colour_text_token` — design-token keys, mirroring `board_stages`).
- `crm_deals` — owning org, `pipeline_id`, `stage_id`, `account_id null`, `name`, `value_minor bigint` + `currency char(3)` (ISO 4217, default from module settings), `expected_close_date`, `status`, `closed_at`, `lost_reason`, `owner_profile_id`, `source`, timestamps. `crm_deal_contacts` (deal, contact, `role` e.g. decision maker/champion).
- Seed one default pipeline for the BespokeLMS org (e.g. Enquiry → Qualified → Demo → Proposal → Negotiation → Won/Lost) — **as data, editable in the UI**, not hard-coded.

**`031_bespokelms_crm_segments_and_provenance`**
- `crm_segments` (owning org, name, `kind static|dynamic`, `definition jsonb` for later dynamic rules), `crm_segment_members` (segment, contact, added_by/at). Membership of a *marketing* segment is not permission to email it — send-time consent checks belong to the consent module (§6).
- `crm_external_links` (C10) — owning org, `entity_type`, `entity_id`, `provider` (`freshsales, hubspot, …`), `external_id`, `payload_hash`, `synced_at`. Unique `(owning_organization_id, provider, entity_type, external_id)`.
- `crm_import_batches` / `crm_import_rows` — staging for §10 (status, raw payload, mapped payload, `dedup_match jsonb`, outcome), so imports are dry-runnable, reviewable and reversible.
- `crm_erasure_log` — who was erased, when, by whom, scope of anonymisation (GDPR accountability; the record itself holds no personal data post-erasure).

---

## 5. Module enablement & authorisation

**Route layer:** `/crm` route group behind `auth` + new `EnsureModuleEnabled:sales_crm` middleware (404 for orgs without the module — same non-disclosure philosophy as `EnsurePlatformOwner`) + a role gate (admin tiers of the org; the future R2 RBAC expansion can add a dedicated `crm_user` capability — nav visibility already stores roles as text precisely so this needs no schema change). Destructive/config actions (`pipeline edit`, `import commit`, `erasure`, `export`) additionally take `platform.sudo` step-up.

**Laravel layer:** per pattern — `ReadsCrmAccounts` / `WritesCrmAccounts` / `ReadsCrmTimeline` / `WritesCrmActivities` / `ReadsCrmDeals` / … contracts, `SupabaseCrm*` implementations that all construct through a single `CrmScope` (owning org resolved from the session profile, C2), Form Request validation on every write, `WritesAuditLog` on every mutation, thin controllers (`CrmAccountController`, `CrmContactController`, `CrmDealController`, `CrmActivityController`, `CrmDocumentController`, `CrmSegmentController`, `CrmImportController`). Writer instances resolved via `app()` (the documented shared-instance DI gotcha).

**UI:** tokens only; `<x-data-table>` shell for Accounts/Contacts/Deals lists (multi-select, bulk actions, row actions, pagination already built); record detail pages use page-tabs (Overview · Timeline · Contacts/Accounts · Deals · Documents) — which lands on the nav builder's R12 `page_tabs` backlog item (§7); WCAG 2.2 AA (keyboard-operable timeline composer, table semantics, 44px targets); mobile-first — lists collapse to cards, the Kanban board gets a desktop-gate with a list fallback rather than a broken squeeze.

---

## 6. GDPR & consent architecture

*(I'm not a lawyer — treat this as engineering architecture for compliance, and have a professional review the DPA/notice wording.)*

**Controller/processor map (drives everything):**

| Data | Controller | BespokeLMS-the-company's role |
|---|---|---|
| BespokeLMS org's CRM (prospects, tenant buyers) | Teach HQ Ltd (you) | Controller |
| A tenant's CRM space (e.g. Turner Price's) | That tenant | Processor — needs a DPA covering CRM data |
| Learner/profile data inside tenants | Tenant (or their client) | Processor |
| Cross-boundary copying | — | **Prohibited by design** (C3) |

**Lawful bases, recorded not assumed.** Every contact carries `source`/`source_detail`; module settings record the default lawful basis per purpose (B2B prospecting under **legitimate interests** with a documented LIA; email marketing subject to **PECR** — corporate-subscriber nuance for B2B email, consent for individual subscribers; B2C almost always consent). Art. 14 matters for imports: prospects who never gave you their data directly must receive privacy information within a month of import or at first contact — make this a checklist step in the import flow (§10).

**Consent module contract (coming soon — design the seam now).** The consent module owns truth: `consent_records(subject → crm_contact_id or profile_id, purpose, channel, status, lawful_basis, evidence, captured_at, withdrawn_at)` plus cookie consents. The CRM *reads* consent; it never stores its own opt-in booleans (only the `do_not_contact` hard stop, which is an objection flag, not consent). **Enforcement point = send time, in the outbound module** — a segment send filters through consent + `do_not_contact` at dispatch, so a stale list can never override a withdrawal. This single seam also serves cookie banners and marketing-list membership later.

**Data-subject rights.** Right to erasure: anonymise the contact in place (null personal fields, keep FK skeleton so deal/revenue history survives lawfully), cascade to activity bodies and documents, log to `crm_erasure_log`, propagate to linked `crm_external_links` providers when sync exists. SAR export: per-contact JSON/CSV bundle (contact + activities + documents list + consents) — a controller action, sudo-gated, audited. Retention: `tenant_modules.settings.crm_retention_months` (suggest 24–36 for engagement-less prospects) + a scheduled purge job with a review queue rather than silent deletion.

**Residency & security.** Supabase project is already `eu-west-1` (Ireland) — UK→EEA is fine under the adequacy decision (keep an eye on its renewal). CRM bucket private with prefix RLS; service-role scoping discipline per C2; step-up auth on exports/erasures; everything audited.

---

## 7. Navigation — via the menu builder, and what the builder is missing

Per your rule: **no hard-coded nav**. The sanctioned pipeline is: add registry entries in code → `nav:sync-registry` → place/publish via the CMS Builder. Plan:

**Registry additions (code-first, one entry each):** `ops.sales-crm` flips `planned → live` (route `crm.home`) when Phase 1 ships; new entries `ops.crm.accounts`, `ops.crm.contacts`, `ops.crm.prospects` (the Leads/Prospects filtered view, C5), `ops.crm.deals` ("Opportunities"), `ops.crm.activities`, `ops.crm.segments`, `ops.crm.settings`, `ops.crm.imports` — matching your second screenshot (Overview = `crm.home`).

**Menu:** a new `crm-subrail` menu (same `subrail` menu type the Outbound sub-rail uses), so the CRM gets its own left rail like your Freshsales screenshot, managed and role-gated in the builder like every other menu.

**Builder shortfalls this exposes → build as builder improvements, not workarounds:**

1. **Menu create/duplicate in the builder UI** — today new menus are seeded by migration (already on your backlog). The CRM sub-rail is the forcing function: ship "Create menu (from template)" in the builder, then create `crm-subrail` *through the builder*.
2. **Tenant-module visibility dimension** — item visibility is role-based only; `route_registry.feature_flag` is global. Add a `module_key` gate (registry column + resolver check against `tenant_modules` for the viewer's org) so CRM items vanish for orgs without the module — no per-tenant menu forks needed. This immediately serves every future Operations module.
3. **`page_tabs` rendering (existing R12 backlog)** — CRM record pages are the first real consumer of managed page-tab menus.
4. **Badge sources** — `badge_source` exists on items; register CRM count providers (e.g. overdue tasks on Activities) rather than hard-coding badges.

**Quick actions:** the header quick-actions widget is per-role and composed in code (by design — the menu controls placement, not internals). Add CRM actions (`New contact`, `New account`, `Log activity`, `New deal`) surfaced only when the viewer's org has the module. This respects the builder architecture: the *slot* stays managed, the action list stays code.

---

## 8. Communication-module integration (the timeline)

One ingestion contract (C8): `RecordsCrmActivity` — called by any channel that sends/receives a message involving a recipient matching a CRM contact **in the sending org's own CRM scope only**. Wire-up order: system/branded emails via `TenantMailer` now (activity row: type `email`, direction `outbound`, `channel_refs` → provider message id; bodies stored in the CRM, not in `email_send_logs`, C7); manual logging (calls, meetings, notes, tasks) in Phase 1 UI; each `coming_soon` channel (Transactional, Marketing, SMS, WhatsApp, Social) calls the same contract when it launches; inbound email later via provider webhooks (Resend inbound / IMAP) matched by sender within scope.

The timeline view itself is a single reverse-chronological feed per account/contact/deal with type filters — the "timeline of all communication" you asked for, plus tasks with due dates giving the Activities menu item its content.

## 9. Contacts who become platform users — auto-detection (your follow-up)

Mechanism: on profile creation (and a nightly catch-up command), match `profiles.email` to `crm_contacts.email` where the CRM's owning org **legitimately owns the relationship**: the contact's owning org is the profile's own org, or the contact belongs to an account whose `organization_id` (C1 promotion link) is the profile's org or its ancestor operator. On match: set `profile_id`, `profile_link_method = auto_email_match`, write a `system` activity ("Became a platform user"), audit. Never link across controller boundaries (a Turner Price school learner never links into BespokeLMS's CRM — C3 holds).

Training data: per your steer, this is **account health, not selling ammunition**. The account page gets an engagement panel — aggregate, service-role reads scoped through the promotion link: seats, active users (30d), completions, last activity. Deliberately excluded: per-learner training records as segment/filter criteria, exporting learner lists into marketing segments — that would repurpose processor data for marketing (purpose limitation). Individual linkage stays at the level of "this contact is a user; last active <date>" on the contact card.

## 10. Freshsales migration (accounts + contacts first)

1. **Extract** via the Freshsales API (`…myfreshworks.com/crm/sales/api/`) with a scoped API key: contacts, accounts (sales_accounts), notes, tasks, appointments, deals; CSV export as fallback. Attachments pulled per record.
2. **Stage** into `crm_import_batches` / `crm_import_rows` — raw payload preserved, field mapping applied (Freshsales → BespokeLMS: account↔contact links map to `crm_account_contacts`; Freshsales lifecycle/status → `crm_lifecycle_stage`; owner emails → `owner_profile_id`; every row gets `source = import_freshsales` + `crm_external_links` row with the Freshsales id — which is also the seed for future two-way sync, C10).
3. **Dry run** — a review screen (data-table) showing per-row outcome: create / merge-candidate (email exact within scope, `pg_trgm` fuzzy on name+domain) / skip, with counts. Nothing commits until you approve; commit is sudo-gated and audited; a batch can be rolled back (delete by batch id) before any post-import edits.
4. **Documents & history** — notes/tasks/appointments become `crm_activities` with original timestamps in `happened_at`; attachments upload into `crm-documents` under the owning-org prefix.
5. **GDPR step** — import checklist records lawful basis carried over and flags contacts needing an Art. 14 notice; consent states import into the consent module when it lands (until then, conservative default: no marketing sends to imported contacts without a recorded basis).
6. **Verify** — reconciliation report (source counts vs created/merged/skipped) delivered before Freshsales is switched off. Run the import into the **BespokeLMS org's CRM scope** (it's your Teach HQ/FoodComplianceHQ/BespokeLMS book of business; own-brand operators can get their own scoped import later if you want the books separated per brand — open decision D4).

## 11. Phasing

| Phase | Contents | Unlocks |
|---|---|---|
| **0 — Foundations** | Migration 028 (`tenant_modules`), `EnsureModuleEnabled`, registry entries + `crm-subrail` (builder-created — builder improvement #1), module-gated visibility (#2), `/crm` Overview shell with real empty states (no dummy data) | Menu goes live gated; every later Operations module inherits the layer |
| **1 — Core objects** | Migration 029; accounts/contacts/junction CRUD (data-table lists, detail pages w/ page-tabs), manual timeline (notes/calls/meetings/tasks), documents + bucket, lifecycle stages + Leads/Prospects view, quick actions | The working address book + "timeline of all communication" |
| **2 — Users & engagement** | Auto-link job (§9), engagement panel, "Convert to tenant" promotion flow | March Foods scenario end-to-end |
| **3 — Pipeline** | Migration 030; pipelines/stages/deals, Kanban + list views, basic forecast rollups, won-deal → board-engine handoff | Opportunities menu item |
| **4 — Freshsales import** | Migration 031 (staging/links/segments/erasure), import pipeline (§10), dedup/merge UI | Freshsales switch-off |
| **5 — Comms & compliance depth** | `RecordsCrmActivity` wired to system emails; segments (static); SAR export; erasure flow; retention job; consent-module seam | "All comms in one app" within controller boundaries |
| **6 — Later** | Dynamic segments, third-party sync connectors (Freshsales/HubSpot via `crm_external_links`), inbound email capture, AI scoring/next-best-action via existing `ai_integrations`, per-brand CRM scopes | The full suite evolution |

Each phase ships lint-clean (Pint/PSR-12), token-only styling, WCAG 2.2 AA, audited writes, and migrations applied via the connector with post-apply validation — the established working pattern.

## 12. Open decisions for you

**D1 — CRM scope for your own brands:** one book of business under the BespokeLMS org, or separate CRM scopes per own-brand operator (TeachHQ, FoodComplianceHQ)? (§10, C11 — affects where the Freshsales import lands. My default: single BespokeLMS scope first; per-brand split is possible later because everything is org-keyed.)
**D2 — Who inside a tenant sees CRM:** admin tier only at first (my recommendation), or start the R2 RBAC expansion now for a dedicated sales role?
**D3 — Retention default:** 24 or 36 months for engagement-less prospects?
**D4 — Deal currency:** GBP-only first (simplest), or multi-currency from day one? (Schema supports both; UI/forecast is simpler single-currency.)
**D5 — Leads/Prospects as saved view (C5)** — confirm you're happy dropping a separate Leads object.
