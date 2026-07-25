# BespokeLMS — Navigation Menu Builder
## Specification v3.1 + Codebase-Grounded Implementation Plan

**Date:** 24 July 2026 · **Status:** REQUIREMENTS CONSOLIDATED — no development started
**Inputs:** (a) Andrew's v3.1 specification (live audit of app.bespokelms.com + legacy TeachHQ owner menu + agreed design decisions); (b) a full code-and-schema audit performed today against the `bespokelms-app` repo and the live Supabase project `pqmdtqsscyltykgcwwus` (74 tables).

This document is the single source of truth for the feature. Part A restates the v3.1 specification with **verification annotations** (✔ confirmed in code/DB · ✎ corrected against code · ⚑ needs a decision, see Part C). Part B maps the spec onto the existing architecture as a concrete implementation plan. Part C lists every reconciliation item. Appendix A is the full route manifest from `routes/web.php` — **closing v3 open item #1** with code-level truth (including un-linked and write-only routes no crawl can see).

---

# Part A — Specification (v3.1, verified)

## A1. Overview

A managed left-hand **Navigation Menu Builder**, administered from **CMS Builder → Navigation Menus**, replaces the partly hard-coded sidebar with a data-driven system rendering **scope-, permission-, and tenant-aware** menus from a validated **route registry**. It separates **Platform** from **Tenant** scope, adds **Operations** (Sales/Marketing/Support) and **Product Development** (internal engineering) as first-class domains, consolidates cascading content under a **Global Content** model, and styles menus via the live **Supabase design-token system**. Unbuilt destinations render as **Coming soon** placeholders, visible to the Platform Owner only.

## A2. Objectives & non-goals

**Objectives:** managed menus under CMS Builder; preserve permissions, route-safety, tenant-context, feature-flags, fallback; support My/Team/Platform + three tenant subtypes; expose live pages and flag legacy as Coming soon; add Operations and Product Development domains.

**Non-goals:** building the underlying Operations/Dev feature pages; migrating legacy data; rebuilding deep Settings (remain in-page anchored sections); learner-facing navigation. ✎ *Read as "no learner UX redesign": the My rail is still seeded and rendered through the system (it appears in §A5 and the acceptance criteria as Live); the only learner-visible change is that "Soon" teasers disappear (today `my-nav.blade.php` shows them to everyone). Confirm — R3.*

## A3. Glossary & status vocabulary

Scope = My · Team · Platform · Tenant. Tenant subtype = reseller · internal · specialist-support ⚑ *(DB `operator_subtype` holds `reseller` · `inhouse` · `own_brand` — mapping decision R1)*. Route key = stable ID a menu item targets. Support ownership = platform · subject · hybrid.

| Status | Meaning | Renders as |
|---|---|---|
| Live | Verified working | Clickable link |
| Live (external) | Works, third-party (Freshworks) | Link, new tab |
| Planned | Intended, unverified | Placeholder — Owner only |
| Coming soon | Legacy to rebuild, no URL | Placeholder — Owner only |
| Hidden | Suppressed by toggle/condition | Not rendered |
| Retired | Being dropped | Not rendered; kept for audit |

URL column always holds a URL or "—"; build state lives only in Status.

## A4. Design principles

Two-level sidebar, grouped **collapsible** sections (multiple open — not accordion); scope before decoration (tenant items appear only with tenant context); per-user persisted open/collapsed + icon-rail state; **route registry not free URLs**; ⌘K palette owns page-jump while header search owns records; deep settings use in-page anchors, never a third nav level.

✎ *Today's rails are non-collapsible flat groups with a text-only active state and a fixed-width rail (`w-rail` token). Collapsible multi-open groups, per-user persisted nav state, and icon-rail/flyout modes are upgrades introduced by this feature (rollout timing R5; state persistence mechanism in B4).*

## A5. Verified route inventory

Patterns confirmed against code: scope roots `/my`, `/team`, `/platform` ✔; platform sub-pages are real named routes ✔; Monitor items + Platform Settings are anchors on `/platform` ✔ *with corrected IDs below*; tenant config is one page with `#section` anchors ✔ *exact match*.

**My (`/my`):** My Learning `/my` (Live) ✔ · Course Library `/my/courses` (Live) ✔ · My Achievements (Coming soon) ✔ · Resources (Coming soon) ✔ · Help & support (Live) ✎ *not a route — a JS action (`openChat()` opens the help drawer); registry needs the `action` route_type whitelisted for it (B2)*.

**Team (`/team`):** Team Dashboard `/team` (Live) ✔ · Team Members (Coming soon) ✔.

**Platform:**

| Group | Item | URL | Status | Verified |
|---|---|---|---|---|
| Platform | Tenants | `/platform` | Live | ✔ `platform.home` |
| Global Content | Global Courses | `/platform/courses` | Live | ✔ `platform.courses` |
| Platform | Widget Library | `/platform/widgets` | Live | ✔ `platform.widgets` |
| Platform | Outbound → System Emails | `/platform/outbound/system-emails` | Live | ✔ `platform.outbound.system-emails` |
| Platform | Platform Settings | `/platform#settings` | Live (anchor) | ✎ real ID is `#settings-content` |
| Integrations | AI & Voice | `/platform/ai` | Live | ✔ `platform.ai` |
| Integrations | Email | `/platform/email` | Live | ✔ `platform.email` |
| Monitor | Platform Users | `/platform#users` | Live (anchor) | ✎ real ID `#users-content` |
| Monitor | Usage & Analytics | `/platform#analytics` | Live (anchor) | ✎ real ID `#analytics-content` |
| Monitor | Integration Logs | `/platform#logs` | Live (anchor) | ✎ real ID `#logs-content` |
| Monitor | Security | `/platform#security` | Live (anchor) | ✎ real ID `#security-content` |

✎ *Anchor correction (verified by grep of `platform/home.blade.php`): every claimed anchor exists but with a `-content` suffix (`#tenants-content`, `#courses-content`, `#settings-content`, `#ai-content`, `#users-content`, `#analytics-content`, `#logs-content`, `#security-content`). Decision R8: registry stores the real IDs, or a one-line engineering pass adds clean alias IDs. Recommendation: add clean IDs (stable public anchor contract) during Phase 3.*

Outbound sub-items (Coming soon, owner-visible): Transactional, Marketing, SMS, WhatsApp, Social Media, Notifications, Score Messages, Logs ✔ *(all present as "Soon" in `outbound-nav.blade.php`)*.

**Tenant — `/platform/tenants/{uuid}#{section}`** (one page, anchors): `#overview` · `#branding` · `#domain` · `#clients` · `#users` · `#courses` · `#ai` · `#email` — ✔ **exact match**, all eight IDs verified in `platform/tenants/show.blade.php`. Tenant UUIDs on file confirmed against the live 9-org estate (8 tenants + the BespokeLMS platform org, correctly excluded from the tenant list).

**Planned future domains:** Operations (Freshworks: Sales CRM, Marketing, Support Desk/Portal/Live Chat/KB, Reports); Product Development (Freshrelease-backed, internal-only: Backlog, Sprints, Roadmap, Releases, Bugs) ✎ *note: the migration-008 board engine (boards, stages, work items, sprints, change records — seeded with the live Course Production board) already exists in the DB with no UI entry point; the Product Development menu can reference it as the native replacement target from day one*; Global Content (Learning Pathways, Policies, Resources, Support Articles).

## A6. Domain models

**A6.1 Global Content cascade** ✔ verified live for courses (`owner_org_id` null = platform catalogue, `course_visibility` + `course_entitlements` + `can_see_course()`, migrations 003–010) and widgets (`dashboard_widgets` platform-owned + role-filtered). Authored at Platform as platform original → inherited by tenants → optional per-tenant override (`tenant_course_overrides`, `tenant_category_overrides` tables already exist ✔). Types: course, widget (Live); pathway, policy, resource, support_article (Coming soon; Policies depends on the undeveloped Policy Management module — R7). `cms.widgets` as a separate tenant route is dropped — widgets are platform records, scope-filtered ✔ *consistent with the built Widget Library*.

**A6.2 Operations & support ownership:** Platform Operations runs the group with brand filtering. Tenant by subtype — reseller: Sales/Marketing/Support; internal: hidden unless enabled; specialist-support: Subject Support only. Ownership: platform · subject · hybrid. Support Articles authored in Global Content, consumed via Support → Knowledge Base.

**A6.3 Product Development (internal-only):** never tenant-visible; gated by feature flag `internal_engineering` + role ∈ {owner, developer, product_manager} ⚑ *`developer` and `product_manager` are not in the live 5-tier role enum — R2*.

**A6.4 Inheritance:** platform original → tenant inherit → optional override; unedited tracks original; only approved token-registry variables (`app_name`, `user_name`, `reset_url`, `expires_in`, `support_email`) insertable ✔ *matches the built Outbound system-email templating*.

**A6.5 Supabase design tokens** ✔ all verified present in the live `design_tokens` table (57 rows; `teachhq*` utilities are compiled aliases of `--color-brand-primary*`, so DB overrides cascade correctly):

```
Brand core: --color-brand-primary · --color-brand-primary-dark ·
            --color-brand-primary-soft · --color-on-brand
Surfaces:   --color-paper · --color-slatecard ·
            --color-brand-bg · --color-brand-surface
Buttons:    --color-button-primary · --color-button-primary-hover ·
            --color-button-primary-text
Accent:     --color-brand-accent · --color-brand-accent-strong ·
            --color-brand-on-accent
Shape:      --radius-control · --radius-panel
```

## A7. Route registry (data model)

```
route:
  route_key (PK, immutable) · label · url|null · route_type[page|anchor|external|section|action]
  scope[my|team|platform|tenant|operations|product_development|shared]
  tenant_required · tenant_subtypes[]
  required_permission|null · feature_flag|null
  support_ownership[platform|subject|hybrid|none]
  content_type|null · status[live|live_external|planned|coming_soon|hidden|retired]
  visible (default true) · legacy_source_url|null · updated_by · updated_at
```

Menu items reference `route_key`; the renderer resolves at runtime so one registry change propagates to every menu variant. Free URLs exist only when `route_type = external`. Per-user preference `nav.show_upcoming` (default true, Owner only).

✎ *Two additions to the v3.1 model, both required by verified reality: (1) `route_type: action` for the whitelisted client actions (`openChat` is live today); (2) internal destinations store the Laravel **route name**, not a URL string — URLs are derived via `route()` at render time so path changes never break menus, and `Route::has()` guards render (B2). `page` vs `section`: `page` = named route; `section`/`anchor` = named route + fragment.*

## A8. Runtime rendering

**A8.1 Layered visibility (deterministic, server-side; non-owners never receive gated entries):**

```
1 visible = false                                   → hidden for all (audited)
2 status ∈ {retired, hidden}                        → hidden
3 internal_only AND role ∉ {owner, dev, pm}         → hidden
4 status ∈ {coming_soon, planned} AND role ≠ owner  → hidden
5 status ∈ {coming_soon, planned} AND owner
    AND nav.show_upcoming = OFF                      → hidden (own view only)
6 scope / tenant_required / tenant_subtype          → evaluate
7 required_permission / feature_flag                → evaluate
8 else                                              → show
```

**A8.2 Sidebar behaviour:** two-level max; tenant groups only with tenant context; auto-open active group; multi-open; persist open/collapsed + icon-rail state per user; highlight selected; hide inaccessible.

**A8.3 Menu-state token binding:** Default `--color-slatecard` fg / `--color-paper` bg · Hover `--color-brand-primary-soft` tint · Focus visible ring ≥ 3:1, never removed · Active (press) `--color-brand-primary-dark` · Selected `--color-brand-primary` bg + `--color-on-brand` fg + left indicator, parent auto-opens · Disabled (planned/coming-soon, Owner only) muted `--color-brand-surface` + "Soon" badge + `aria-disabled="true"` + tooltip · Hidden absent from DOM. Shape via `--radius-control` (items) / `--radius-panel` (flyouts). Selected (persistent) ≠ Active (transient). ✎ *The Selected treatment is richer than today's text-only active state (`font-semibold text-teachhq-dark` + `nav-ico`) — rollout timing R5.*

**A8.4 Fallback:** on CMS/registry failure render a hard-coded safe menu (Overview, Tenants, Global Courses, Settings — plus the workspace switcher); log and surface to the Platform Owner. ✔ *Same philosophy as the live brand-token fail-safe (reader error → compiled defaults hold).*

**A8.5 On-page tabs (segmented controls) — fourth menu surface.** The frozen prototype (`teachhq-dashboard-tailwind.html`) carries a proven in-page tab pattern the builder should also manage: a shared `.seg` segmented control (CSS-grid track, `--segs` column count, `data-active` index, sliding `.seg__pill` translating N×100% with a 200ms ease, `prefers-reduced-motion` respected) in two variants — `seg--brand` (white track, brand-filled pill, on-brand active text; already ported token-clean into the app as `.ws-switch` for the workspace switcher) and `seg--paper` (paper-tone track, white floating pill with soft shadow, slatecard active text; used in the prototype for the Team/Site/Group/Trust scope switcher and the six-tab Platform View selector Overview/Customers/Users/Courses/Financial/Compliance). A third prototype pattern — stacked icon+label tabs in the notifications drawer — is drawer chrome, out of nav-builder scope.

In the model this becomes `menu_type: page_tabs`: a managed menu bound to a page region whose items reference `section`/`anchor` registry entries (in-page panels) or sibling routes (sub-pages) — the natural managed rendering for the `/platform` Settings/Monitor sections and for any future multi-panel console page. Two build notes, both mandatory: (1) **the prototype markup is reference-only** — it is full of hard-coded values (`#fff`, `#e2e8f0`, `#64748b`, `sky-50`, raw rgba shadows, 14px/10px radii) that must map to tokens (`--color-surface`, `--color-paper`, `--color-slatecard`, `--color-brand-primary`, `--color-on-brand`, `--radius-control`, the shadow-panel token, and the existing `--duration-*` motion tokens; anything missing enters `design_tokens` first). The app's `.ws-switch` is the token-clean port to generalise — one shared component, `brand` and `paper` variants. (2) **Accessibility upgrade required**: the prototype's seg buttons are bare `onclick` buttons with no tab semantics; the managed component must implement the full ARIA tab pattern (`role="tablist"`/`role="tab"`, `aria-selected`, arrow-key navigation, panel `role="tabpanel"` association) — matching the WCAG 2.2 AA standing requirement. Fidelity detail: the prototype's pill CSS only defines `data-active` 0–3; its six-segment selector moves the pill via JS — the shared component should derive position generically from index as `.ws-switch` already does.

## A9. CMS Builder → Navigation Menus (admin — Coming soon until built)

Screens: menu list · create/edit · group & item builder · conditions · preview · version history · publish. Builder: drag-drop, **route-key selection (never free URL)**, icons, badges, default-open, per-item Show/Hide (versioned), max-depth-2 validation. Conditions: roles, scopes, requires-tenant, tenant types, feature flag, support ownership, internal_only. Preview personas: Owner, Admin, Sales/Marketing/Support Managers, Tenant Owner, Tenant Sales/Support Users, Content Manager, Developer/PM, and the three tenant subtypes ⚑ *R2 — most personas exceed the live role enum; preview renders not-yet-real roles as "role pending" mapped to the nearest current equivalent*. Versioning: draft, compare, publish, rollback, full audit log.

**Menu list columns:** name · scope · tenant subtype · status · last published by/date · version count. **Create/edit fields:** name · menu key · scope · tenant subtype · default assignment · duplicate-from · internal notes.

## A10. Two visibility controls (distinct)

1. **Runtime toggle** — `nav.show_upcoming` (Owner-only): declutters the Owner's own view of Planned/Coming-soon placeholders; affects nobody else; not versioned.
2. **Builder Show/Hide** — per-item `visible` flag: hides globally for everyone; versioned with the menu and audited on publish. Independent of `status`.

## A11. Search & command access

Header search = records only ("Search tenants, courses or users" ✔ verified live). Page-jump = ⌘K command palette with separate "Go to / Pages" and "Records" groups; the palette consumes the same resolver output as the sidebar so visibility gating is identical by construction; the registry doubles as the page index. Scheduled in the optimisation phase, not v1.

## A12. Freshworks principle

The whole suite (Freshsales, Freshmarketer, Freshdesk, Freshchat, Freshrelease) is **embed-first, replace-later**: surface now as `route_type: external` / status Live-external where wanted immediately, or hold as Coming soon; native rebuilds later swap the registry entry to an internal route key — menus never change. Formal embed-vs-replace decision = R6.

## A13. Stakeholders

Platform Owner (global structure/governance) · Platform Admin (menu CRUD/rollout) · Sales/Marketing/Support Managers (Operations views) · Tenant Owner (tenant nav by business model) · Tenant Sales/Support Users · Content Manager (Content + CMS Builder) · Developer/Product Team (route registry, Product Development, fallback, flags). ⚑ *R2: in v1 only the Platform Owner exists with editing rights; the rest arrive with the RBAC expansion.*

## A14. Acceptance criteria

- Platform user sees a short scoped nav with **Tenants, Global Courses, Widget Library, AI, Email, Outbound/System Emails** as Live — ✔ all verified routable today (Appendix A).
- My/Team dashboards and Course Library render Live at `/my`, `/team`, `/my/courses` — ✔ verified.
- Platform Owner sees all Planned/Coming-soon items as disabled badged placeholders; all others see none (server-side excluded).
- Owner toggles **Show upcoming** without affecting others; builder **Show/Hide** removes an item for all, versioned and audited.
- Reseller tenant sees Operations + Content + CMS + Commerce + tenant config; internal tenant hides Sales/Marketing unless enabled; specialist tenant sees Subject Support only — ⚑ end-to-end testable only after R1 + R2.
- **Product Development** visible only to Owner/Developer/PM with `internal_engineering`, never in any tenant scope.
- Global Content edits at Platform scope set the inherited default; a tenant override affects only that tenant — ✔ the verified courses/widgets pattern.
- Only approved tokens insertable; unknown tokens rejected on save.
- No menu exceeds two levels; tenant config uses `#section` anchors, not separate routes — ✔ matches the built config hub.
- Styling resolves via Supabase design tokens with platform-default fallback — ✔ the live `ThemeResolver` chain.
- CMS-config failure falls back to the safe system menu.

---

# Part B — Implementation plan (grounded in the existing architecture)

## B1. What the builder replaces (current state)

Navigation lives in five Blade components with structure baked into PHP arrays: `workspace-switcher` (My/Team/Platform pills; Platform gated by `isPlatformOwner()`; sliding-pill JS already parameterised via `--ws-count`/`--ws-index`), `platform-nav`, `my-nav`, `team-nav`, `outbound-nav` (sub-rail). All share one token-driven markup language (bg-paper container, uppercase brand group headers, `rail-item` rows, inline-SVG icons, "Soon" pill). **Parity seed = zero visual change** except the agreed one (upcoming items vanish for non-owners).

The app's authorisation pattern the nav must mirror: `platform.*` routes 404 (not 403) to non-owners — forbidden items are *absent*, never disabled. Identity = `SupabaseUser` session snapshot (5-tier role, org id/type); data access = service-role PostgREST via `Reads*`/`Writes*` contracts.

Established precedents reused: `dashboard_widget_visibility` (role-grant rows) → item visibility; `design_tokens`/`ThemeResolver` (code-mirrored seed, cached resolver, flush-on-save, graceful fallback) → registry sync + `NavigationResolver` + A8.4 fallback; Widget Library console (`platform.sudo` step-up, `audit_log`) → builder write path; `dashboard_widgets.icon` → icon storage; `data-table` component → menu list.

## B2. Database schema (Supabase conventions, additive, RLS on everything, declarative migration)

New tables (next free migration numbers at build time): **`route_registry`** — the A7 model verbatim, plus `route_name` (internal Laravel route name; `url` derived at render), `action` (whitelisted enum), `default_icon`, `synced_at`; CHECK constraints enforce exactly-one destination per route_type and "Live requires a destination". **`feature_flags`** (key, enabled, description) — minimal but real, so flag conditions aren't fabricated; `internal_engineering` and `nav.data_driven` are the first rows. **`nav_menus`** (key, name, scope, menu_type switcher|rail|sub_rail, nullable `organization_id` — null = platform-defined global, the column that later enables per-tenant menu overrides brand-kit-style, v1 always null; default_assignment, notes). **`nav_menu_versions`** (menu_id, version_no, state draft|published|superseded, published_by/at; partial-unique one draft + one published per menu) — publish copies draft→new published version; rollback republishes an earlier one. **`nav_menu_items`** (version_id, parent_id depth ≤ 2 validated on save, item_type group|link, route_key FK, label/icon overrides null = inherit registry, badge_source, default_open, `visible`, sort_order). **`nav_item_visibility`** (item_id, role **as text** — future roles need no migration). Registry-level conditions (tenant_subtypes, feature_flag, support_ownership, internal_only, required_permission) live on `route_registry` per A7 — a destination carries its gating everywhere it appears; per-item conditions can be layered later if ever needed.

RLS mirrors the widget library: authenticated `select using (true)`, writes `is_platform_owner((select auth.uid()))`. Known hardening note: open reads mean Planned labels are DB-readable via PostgREST even though never rendered — fine for labels, remember before putting anything sensitive in registry descriptions. `nav.show_upcoming` + per-user open/collapsed/icon-rail state persist on the profile (preferences pattern already used for theme).

**Registry sync:** code-first declaration `app/Support/Navigation/RouteRegistry.php` + `php artisan nav:sync-registry` (deploy-time + on-demand): upserts, marks code-removed keys `retired`, warns when a `live` internal entry fails `Route::has()`. Code is the source of truth; the DB is the runtime copy the builder reads — the exact design-token pattern.

**Seed:** lifts the five components verbatim (groups, labels, icon paths, order, today's effective role visibility) as version 1 published of each of the five menus (`workspace-switcher`, `platform-rail`, `my-rail`, `team-rail`, `outbound-subrail`), plus registry rows for the full A5 inventory: 20 live internal destinations, the verified anchors, `openChat` as the one action, today's Soon items as `coming_soon`/`planned` per the A3 definitions, and the future-domain entries.

## B3. Application layer

**Read path:** `Contracts/ReadsNavigation` + `SupabaseNavigation` (service-role reader) + `Support/Navigation/NavigationResolver` — the `ThemeResolver` sibling. Applies the A8.1 layered algorithm exactly, in order, plus `Route::has()` guard on internal entries (drop + builder-flag on failure), label/icon inheritance, sort, active-route detection (Selected state + parent auto-open). Cached ~10 min keyed by (menu, published-version, role, owner-flag, subtype, flag-hash); explicit flush on publish. Fallback per A8.4 if the read fails. Delivered by a `View::composer` on `layouts.app` (the `$brandTokensCss` pattern) so pages need no controller changes.

**Components:** four generic components replace the five hard-coded ones — `nav/rail`, `nav/sub-rail`, `nav/switcher`, plus `nav/page-tabs` (the A8.5 segmented control: one shared component generalised from the token-clean `.ws-switch`, `brand` and `paper` variants, full ARIA tab pattern) — reproducing existing markup at parity, then gaining the A8.2/A8.3 behaviours (collapsible multi-open groups, persisted state, icon-rail, Selected treatment) per the R5 rollout decision. Icons: curated set (existing menu icons + registry defaults) in v1.

**Write path:** `WritesNavigation` contract + thin `NavigationController` + Form Requests whose rules derive from the registry (route_key must exist, not retired), the conditions vocabulary, depth-2, and the approved-token check. Routes join the `platform.owner` group under `platform/cms/…`; **publish and rollback are `platform.sudo` step-up-gated** and written to `audit_log` (they change every user's UI), consistent with branding/widgets/integrations. House gotchas honoured: writer resolved via `app()` in the method, never constructor-injected beside the reader (the Reads+Writes DI collision); no array props through `<x-dynamic-component>` (explicit component tags); companion files committed together (the 2c44ee6 deploy-failure lesson).

## B4. Sequence (v3.1 §14 order × deploy reality)

1. **Discovery — ✅ complete** (this document; Appendix A closes the manifest gap; anchors verified). Remaining: final route-key assignment; classify each legacy prototype area migrate/merge/replace/retire; fix or accept the doubled-prefix route anomaly (Appendix A ⚠).
2. **IA** — sign off Part A trees + this schema; resolve R1–R8.
3. **Core build** — migration + parity seed; registry class + sync command; resolver; component swap behind the `nav.data_driven` feature flag (fallback = old components, still in git). **Gate: per-role parity screenshots** (owner, operator admin, client admin, team manager, learner); the sole expected diff is upcoming items vanishing for non-owners.
4. **Builder** — CMS Builder → Navigation Menus: CRUD, drag-drop (accessible: keyboard move + `aria-live`, drag as enhancement — the dashboard-grid pattern), conditions, persona preview, draft/compare/publish/rollback, sudo + audit.
5. **Operations & Product Development** — created in the builder as data (mostly planned/coming-soon; Freshworks entries per R6; Product Dev pointing at the board engine); Global Content regroup; clean anchor IDs (R8); Selected-state/rail-mode upgrades if R5 chose Phase-4+.
6. **Migration & rollout** — default menus for Platform/Team/My + three tenant subtypes; legacy marked Coming soon; pilot Owner + one reseller + one internal tenant; flag flipped estate-wide; old components deleted.
7. **Optimisation** — ⌘K palette (same resolver, so gating identical by construction); menu-usage/dead-click analytics; grouping refinements.

Deploy mechanics as established: sandbox commits (companion files together, git-lock sweep), **Andrew pushes**, Laravel Cloud auto-builds; `SUPABASE_SERVICE_ROLE_KEY` already set; migrations applied one at a time via the Supabase connector with validation after each. Verification in-sandbox is static (`php -l`, Blade balance, token audit, `node --check`); live checks follow each push.

**Standards:** PSR-12/Pint; thin controllers + Form Requests; Supabase SQL conventions with commented declarative migrations; RLS everywhere; no dummy data (the seed is the real current navigation); tokens only — zero new visual values (new needs enter `design_tokens` first); WCAG 2.2 AA (semantic labelled `<nav>`s, `aria-current`, focus ring ≥ 3:1 never removed, keyboard-operable builder, 44px targets, no colour-only state); mobile-first, with the builder desktop-gated per the established admin-tooling policy.

---

# Part C — Reconciliation items (decisions needed, none blocking Part A sign-off)

**R1 — Tenant subtype vocabulary.** Spec: reseller · internal · specialist-support. Live DB `operator_subtype`: `reseller` · `inhouse` · `own_brand` (Turner Price + Vetlexicon reseller; March Foods inhouse; TeachHQ + FoodComplianceHQ own_brand). Map `internal` ≡ `inhouse`; then either `specialist-support` ≡ `own_brand` or add a new enum value and reclassify (which tenants are specialist-support?). Conditions store subtypes as text[], so either answer slots in.

**R2 — Personas vs the 5-tier role enum.** Spec roles (Platform Admin, Sales/Marketing/Support Manager, Tenant Owner, Tenant Sales/Support User, Content Manager, Developer, Product Manager) exceed the live enum (`bespokelms_owner`, `lms_operator_admin`, `client_admin`, `team_manager`, `learner`). Nav schema is forward-compatible (roles as text), but the RBAC expansion — new roles, RLS helpers, seeding — is a prerequisite workstream for the subtype/persona acceptance criteria and should be scoped separately before Sequence step 5.

**R3 — "Learner-facing navigation" non-goal.** Confirm the A2 reading: My rail seeded and rendered through the system, no learner UX redesign, Soon teasers disappear for learners.

**R4 — Team pill visibility.** Today every role sees the Team pill, learners included. Keep at parity, or scope Team to `team_manager`+ via the new grants? (Seed decision.)

**R5 — Visual upgrade timing.** Filled Selected state + left indicator, collapsible multi-open groups, persisted nav state, icon-rail/flyout modes — all upgrades over today. Introduce at Core-build parity (visible change early) or with the Builder phase? Recommendation: parity first (pure swap, screenshot-comparable), upgrades in the Builder phase.

**R6 — Freshworks embed-vs-replace** — formal decision finalises each Freshworks registry entry (`live_external` now vs `coming_soon` hold).

**R7 — Policy Management module** — dependency for Global Policies; stays `coming_soon` until scoped.

**R8 — Anchor ID normalisation.** Real `/platform` section IDs carry `-content` suffixes; tenant-hub IDs are clean. Store real IDs in the registry now, or add clean alias IDs on `/platform` (recommended, trivial, stable contract).

**Closed:** v3 open item #1 (route manifest) — Appendix A. v3 open item #2 (Operations/Product-Dev pages don't exist) — confirmed by audit; all such entries seed as planned/coming-soon; the board engine exists DB-side for Product Dev to target.

---

# Part D — Seed menu structure (Platform Owner complete menu, supplied 24 Jul 2026)

The agreed v1 menu content — every item across all scopes, live links walked and confirmed by Andrew this session, cross-checked here against the code manifest (Appendix A). This is the data the Phase-3 seed migration loads (subject to R8–R10 below).

## D1. MY scope (`my-rail`)

My Learning `/my` (Live ✔) · Course Library `/my/courses` (Live ✔) · Help & support (Live — `action: openChat` ✔) · My Achievements (Coming soon) · Resources (Coming soon).

## D2. TEAM scope (`team-rail`)

Team Dashboard `/team` (Live ✔) · Team Members (Coming soon).

## D3. PLATFORM scope (`platform-rail`)

**Platform Workspace:** Tenants `/platform` (Live ✔) · Global Courses `/platform/courses` (Live ✔ — see R9) · Widget Library `/platform/widgets` (Live ✔ — see R9) · Platform Settings `/platform#settings` (Live anchor ✎ real ID `#settings-content`, R8).

**Outbound (Communications):** System Emails `/platform/outbound/system-emails` (Live ✔) · Transactional · Marketing · SMS · WhatsApp · Social Media · Notifications · Score Messages · Logs (all Coming soon). ✎ *The Outbound overview route `platform.outbound` (`/platform/outbound`) exists and is live but is not in this structure — decide whether the group header links to it or it retires (R10).*

**Integrations:** AI & Voice `/platform/ai` (Live ✔) · Email `/platform/email` (Live ✔) · Integration Logs `/platform#logs` (Live anchor ✎ real ID `#logs-content`). ✎ *Integration Logs has moved from the Monitor group (v3.1 inventory) into Integrations — treated as the current intent.*

**Monitor:** Platform Users `/platform#users` · Usage & Analytics `/platform#analytics` · Security `/platform#security` (all Live anchors ✎ real IDs carry `-content`, R8).

**Global Content (cascades to all tenants):** Global Courses (Live ✔) · Widget Library (Live ✔) · Learning Pathways · Policies (new Policy module — R7) · Resources · Support Articles (Coming soon). ⚑ *R9: Global Courses and Widget Library appear in BOTH Platform Workspace and Global Content in this structure. The registry model supports multi-placement (items reference route_key), but duplication within one rail is unusual — confirm whether they live in both groups or move to Global Content only.*

**Operations (Platform — Freshworks replacement):** Sales CRM · Marketing · Support Desk · Support Portal · Live Chat · Knowledge Base · Reports (all Coming soon; embed-vs-replace R6 decides any `live_external` interim entries).

**Product Development (internal-only — Freshrelease):** Backlog · Sprints · Roadmap · Releases · Bugs / Issues (all Coming soon; `internal_engineering` flag + R2 roles; native target = the existing migration-008 board engine).

## D4. TENANT scope (`/platform/tenants/{uuid}#{section}`)

One config page per tenant, eight anchor sections, all Live and ✔ code-verified: `#overview` · `#branding` · `#domain` · `#clients` · `#users` · `#courses` · `#ai` · `#email`. Tenant UUIDs on file ✔ match the live 8-tenant estate (All Saints, Demo Academy, FoodComplianceHQ, March Foods, St Mary's, TeachHQ, Turner Price, Vetlexicon). Conditional tenant Operations (Coming soon) gated by subtype: reseller → Sales/Marketing/Support; internal → hidden unless enabled; specialist-support → Subject Support only (R1).

## D5. Cross-check notes

Coverage: every live destination in this structure exists in the code manifest; conversely the manifest holds a few live GETs deliberately absent from menus — course drill-in pages (pricing/availability/content/workflow/edit — reached from the course workspace, not the rail), `/profile` (account dropdown), `/platform/outbound` (R10), and `/` (the frozen prototype root, whose retirement is its own future decision). Status vocabulary note: strictly, never-built items (Operations, Product Development, Learning Pathways…) are **Planned** and prototype-era teasers (My Achievements, Resources, Team Members, Outbound channels) are **Coming soon** under the A3 definitions; the seed can carry the accurate split at no extra cost since both render identically (Owner-only placeholder) — flagged so the vocabulary stays honest (R11: confirm or collapse the distinction).

Additional reconciliation items raised by this structure: **R9** duplicate placement of Global Courses / Widget Library (both groups, or Global Content only?) · **R10** fate of the live `/platform/outbound` overview page (group-header link, plain header, or retired) · **R11** Planned vs Coming-soon classification split (recommend: apply per A3 definitions) · **R12** on-page tabs scope (A8.5): which pages get managed `page_tabs` menus in v1 — proposed: `/platform` Settings/Monitor sections and the tenant config hub's eight sections render as `seg--paper` tabs, with the pattern then available to any future console page; confirm, and confirm the two-variant mapping (brand = switchers, paper = page tabs).

---

# Appendix A — Full route manifest (`routes/web.php`, 24 Jul 2026)

Code-level truth, including un-linked and write-only routes. GET routes are registry candidates; POST/PUT/DELETE are actions, never menu destinations.

**Guest:** `login` GET+POST /login · `password.request` GET /forgot-password · `password.email` POST (throttle 6,1) · `password.reset` GET /reset-password.

**Authenticated:** `dashboard` GET / (frozen prototype + role-aware injection; honours `?ws=` deep links) · `logout` POST · `my.home` GET /my · `my.dashboard.save` POST /my/dashboard · `my.courses` GET /my/courses · `my.courses.show` GET /my/courses/{course} · `team.home` GET /team · `team.dashboard.save` POST /team/dashboard/save · `preferences.theme` POST · `profile.edit` GET /profile · `profile.update` PUT · `profile.avatar` POST · `profile.avatar.remove` DELETE.

**Platform-owner (`platform.owner` 404-gate, prefix /platform):**
`platform.home` GET /platform *(Settings + Monitor live here as `#…-content` anchors)* · `platform.confirm` GET+POST, `platform.confirm.resume` GET *(step-up sudo)* · `platform.courses` GET · `platform.courses.show` GET {course} · `platform.courses.update` PUT · `platform.courses.pricing` GET + `.update` PUT · `platform.courses.availability` GET + `.update` PUT · `platform.courses.content` GET + `.draft`/`.publish`/`.action` POST · `platform.courses.slides.edit` GET + `.update` PUT · `platform.courses.workflow` GET + `.transition` POST · `platform.widgets` GET · `platform.widgets.show` GET · `platform.widgets.update` PUT (sudo) · `platform.tenants.show` GET {tenant} *(config hub, eight verified `#section` anchors)* · `platform.tenants.branding.update` PUT (sudo) · `platform.tenants.alias.update` PUT (sudo) · `platform.ai` GET + `platform.ai.update` PUT (sudo) · `platform.email` GET + `.update` PUT (sudo) + `.test` POST (sudo) · `platform.outbound` GET · `platform.outbound.system-emails` GET · `.edit` GET {key} · `.update` PUT (sudo).

⚠ **Anomaly for Discovery:** `platform.platform.courses.edit` GET `/platform/platform/courses/{course}/edit` + `platform.platform.courses.update` PUT — a doubled `platform/` prefix from re-declaring the prefix inside the group (routes/web.php L107–108). Works, but assign its route key against the normalised intent (`platform.courses.edit`) and fix the declaration during Discovery — exactly the drift class the registry prevents recurring.

**Count:** 20 live internal GET destinations (excluding auth/step-up plumbing) + 12 verified anchors (4 platform + 8 tenant) + 1 action (`openChat`) = the complete v1 registry seed for live entries.
