# BespokeLMS — Multi-tenant white-label LMS
### Re-platform Plan, RBAC, Improvements & Database Schema · v1 (for approval)

*Prepared 22 July 2026. Planning document only — no code written, no database created, the existing prototype untouched. The product is **BespokeLMS** (the white-label platform). **Turner Price** is one operator tenant on it, with its own login and URL. The current prototype's look becomes the default / Turner Price theme; per-operator white-label theming comes later.*

---

## 1. Scope & guiding rules

Build **BespokeLMS**, a multi-tenant white-label LMS on **PHP / Laravel / SQL**, seeded from the current Turner Price prototype, with:

- a **web app** responsive at every breakpoint;
- a **Flutter app** later, sharing the backend (planned, not built);
- **Supabase** — Postgres, Auth, Storage, Realtime;
- a **5-tier role hierarchy** with **three operator business-models** at Tier 2;
- **per-operator login + URL** (Turner Price gets their own branded entry);
- a layered **rollback**;
- a new **Admin → Platform Settings** area to connect **Claude AI**.

Rules: **don't redesign (but apply the review's dark-mode / a11y / responsive / UI-consistency improvements)**, and **mock data only**.

---

## 2. Findings

**a) Linked Supabase project unreachable.** `pqmdtqsscyltykgcwwus` → permission denied; only `vows-wedding-planner` is visible in *Teach HQ Limited* (`ghxqrimfybrpsffezlxn`, free plan). Decision: create a new **`bespokelms`** project — **£0/month**.
**b) Netlify can't run Laravel.** Static prototype stays on Netlify as rollback; Laravel deploys where PHP runs (Phase 7).
**c) Review verified** against the real 336 KB file: matrix `min-width:1180px` (line 200) ✅ · dark mode not implemented ✅ · no skip link ✅ · `aria-current` partly done (admin rail) ⚠️ · keyboard handlers need an audit ⚠️.

---

## 3. Current prototype (inventory)

Single 336 KB HTML file, Tailwind v4 Play CDN, Lato, vanilla JS. Workspaces via `switchWorkspace('my'|'team'|'admin')`: **My** (learner Emma Wilkinson — dashboard + 28-course Library), **Team** (manager — scope switcher + compliance Matrix + `localStorage` saved views), **Admin** (accordion nav incl. *Integrations → API Keys*, *Settings*). Shared: sticky header, notification drawer, chat, preferences panel, RAG palette, `@theme` tokens (`teachhq #009DE1`, `slatecard #3D515B`, `paper #F4F2EF`). Data arrays map cleanly to tables.

---

## 4. Target architecture

```
                 ┌──────────────────────────────────────────────┐
                 │                 Supabase                     │
                 │  Postgres · Auth · Storage · Realtime ·      │
                 │  RLS (cascading by org tree)                 │
                 └──────▲────────────────▲───────────────▲──────┘
                        │ service role   │ JWT(role+org)  │ realtime
       ┌────────────────┴──────┐   ┌─────┴──────────┐    │
       │  Laravel (BespokeLMS) │   │  Flutter app   │    │
       │  Blade + Vite +       │   │  (later; same  │◄───┘
       │  Tailwind build       │   │   Supabase)    │
       │  tenant + role gating │   └────────────────┘
       └───────────────────────┘
```

Multi-tenant routing by **operator slug** (subdomain per operator for the prototype, e.g. `turner-price.bespokelms.app`, or a `/t/turner-price` path). Each operator login lands in their own **data-scoped, branded** instance. **Supabase Auth** is the identity provider (JWT carries role + org); Laravel verifies it and renders only the tabs/nav that role and tenant allow. **JS approach:** carry existing vanilla JS to Vite ES modules first (parity), then Livewire selectively.

---

## 5. Tenancy & role hierarchy (RBAC)

**Five tiers**, each sees its own scope **plus everything below**:

| Tier | Role (`app_role`) | Scope | Tabs |
|---|---|---|---|
| 1 | `bespokelms_owner` | All operators, clients, learners | Platform Admin · Admin · Team · My |
| 2 | `lms_operator_admin` | Their operator's world (see subtypes) | Admin · Team · My |
| 3 | `client_admin` | Own client org's teams + learners | Admin (scoped) · Team · My |
| 4 | `team_manager` | Own team's learners | Team · My |
| 5 | `learner` | Own record | My only (tab bar hidden) |

**Tier 2 splits into three operator business-models** (an org attribute `operator_subtype`, *not* a separate role):

| Subtype | Example | Below them | `has_client_layer` |
|---|---|---|---|
| `reseller` | Turner Price | Client orgs → Teams → Learners | **true** |
| `inhouse` | March Foods | Teams → Learners (org *is* the client) | **false** |
| `own_brand` | TeachHQ, FoodComplianceHQ (BespokeLMS-owned) | Client orgs → Teams → Learners | **true** |

```
Tier 1: BespokeLMS (platform)
  ├── Tier 2a reseller  (Turner Price) → Tier 3 clients → Tier 4 teams → Tier 5 learners
  ├── Tier 2b inhouse   (March Foods)  → Tier 4 teams  → Tier 5 learners   (no client tier)
  └── Tier 2c own_brand (TeachHQ)      → Tier 3 clients → Tier 4 teams → Tier 5 learners
```

**Admin-nav depth is conditional on `has_client_layer`:** reseller/own_brand show **Clients → Teams → Learners** (3 levels); in-house show **Teams → Learners** (2 levels) — no artificial "Clients" step for an org that only manages itself.

**Tab rendering** (Laravel `match($user->role)`): owner `[platform_admin,admin,team,my]` · operator `[admin,team,my]` · client_admin `[admin_scoped,team,my]` · team_manager `[team,my]` · learner `[my]` (hide the tab bar). Rules: learner's single view hides the tab bar; Client Admin's Admin reuses the same component, data-filtered; **tenant switcher** (dropdown by the profile menu) only for Tiers 1–2, icon-only on mobile; a **demo role/tenant switcher** previews every tier + operator type; role-forbidden nav is **not rendered in the DOM** (security + SR hygiene).

**Demo accounts (seeded, mock):**

| Email | Tier / Role | Operator subtype |
|---|---|---|
| `kemp.house+BespokeLMS@googlemail.com` | 1 · Platform Owner | — |
| `kemp.house+TurnerPrice@googlemail.com` | 2 · Operator Admin | reseller |
| `kemp.house+MarchFoods@googlemail.com` | 2 · Operator Admin | inhouse |
| `kemp.house+TeachHQ@googlemail.com` | 2 · Operator Admin | own_brand |
| `kemp.house+ClientAdmin@googlemail.com` | 3 · Client Admin | (under Turner Price / TeachHQ) |
| `kemp.house+TeamManager@googlemail.com` | 4 · Team Manager | — |
| `kemp.house+Learner@googlemail.com` | 5 · Learner (reuses Emma Wilkinson) | — |

---

## 6. Styling & UI — "evolve, don't redesign"

One invisible change: **Tailwind Play CDN → compiled Tailwind v4 (Vite)**. `@theme` tokens + custom CSS port verbatim; Lato stays; classes preserved; the file decomposes into Blade layouts/partials/components. The current look becomes the **default (Turner Price) theme**; per-operator white-label (logo + accent token swap) is a later toggle. **UI-consistency standards applied:** KPI `rounded-xl` / panels `rounded-2xl`; `font-black` only on the primary stat; alpha borders (`slate-900/10` light, `white/10` dark); section labels `tracking-widest text-[10px]`; active nav `bg-teachhq/8` fill; chat `z-index` above the drawer.

---

## 7. Dark mode (missing today — to be built)

`[data-theme="dark"]` token overrides, contrast-checked:

```css
[data-theme="dark"]{
  --color-teachhq:#38b6e8;   /* #009DE1 fails AA for body text (~3.8:1) */
  --color-teachhq-dark:#1a9fd4; --color-slatecard:#8aa0aa; --color-paper:#1e2428;
}
[data-theme="dark"] body{background:#0f1315;color:#e2e8f0;}
[data-theme="dark"] .bg-white{background:#1a1f23;}
[data-theme="dark"] .border-slate-200{border-color:rgba(255,255,255,0.08);}
```

Toggle sets `data-theme` on `<html>`; preference persists in Supabase (`profiles.theme_preference`), not `localStorage`; contrast verified both modes; **toggle in the header** so preferences are reachable at every breakpoint.

---

## 8. Responsive plan — explicit breakpoints

Tailwind defaults (already in use), applied consistently:

| Prefix | Min-width | Targets |
|---|---|---|
| base | 0 | small mobile (~360–430px) |
| `sm:` | 640 | large / landscape phones |
| `md:` | 768 | tablet portrait |
| `lg:` | 1024 | tablet landscape / small laptop |
| `xl:` | 1280 | desktop |
| `2xl:` | 1536 | large desktop |

**Per band:** **0–639** single column · sidebar stacked · header search icon-only · scope → `<select>` · **matrix hidden** (desktop message) · touch ≥44px · bottom tab bar (2+ tabs). **640–767** KPI 2-col · matrix gated. **768–1023** KPI 3-col · sidebar collapsible (fixed 300px too wide) · matrix gated (Flutter tablet app takes over — don't over-invest here). **1024–1279** fixed sticky `lg:w-[300px]` sidebar · KPI 3-col → 6 · tenant switcher visible dropdown · **matrix still gated**. **1280+** full experience · **matrix revealed** · KPI `2xl:grid-cols-6`.

**Matrix reveal = `xl:` (1280px), not `lg:`** (`min-width:1180px` overflows 1024):

```html
<div class="hidden xl:block"><!-- matrix --></div>
<div class="flex xl:hidden items-center gap-3 rounded-xl bg-blue-50 border border-blue-200 p-4 text-sm text-blue-800">
  <p>The compliance matrix works best on a larger screen (1280px+). Please use a desktop browser.</p>
</div>
```

---

## 9. Accessibility (WCAG 2.1 AA)

Keyboard handlers on `role="button"` cards · skip-to-content link · `aria-current="page"` on every rail · ARIA tab pattern on segmented controls/tabs · touch targets ≥44px via `@media (hover:none)` · badge `text-[9px]`→`text-[11px]` · focus-ring `ring-offset-2` · no colour-only meaning · contrast checked light+dark · **role-gated nav removed from the DOM, not hidden**. Formal audit in Phase 6.

---

## 10. Database schema (Supabase / Postgres)

All in `public`, all with **RLS**; `profiles.id` → `auth.users.id`; mock-seeded.

```sql
create type org_type         as enum ('platform','operator','client');
create type operator_subtype as enum ('reseller','inhouse','own_brand');
create type app_role         as enum
  ('bespokelms_owner','lms_operator_admin','client_admin','team_manager','learner');

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  parent_id uuid references public.organizations(id),
  type org_type not null,
  operator_subtype operator_subtype,          -- null unless type='operator'
  has_client_layer boolean not null default true,  -- false for 'inhouse'
  subtype text,                               -- 'trust'|'school'|'site' display parity
  name text not null, slug text unique, location text,
  brand_theme jsonb not null default '{}',    -- per-operator white-label (later)
  created_at timestamptz not null default now()
);
-- Examples: BespokeLMS(platform) → Turner Price(operator,reseller) → School A(client) → teams → learners
--           BespokeLMS(platform) → March Foods(operator,inhouse, has_client_layer=false) → teams → learners

create table public.teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  name text not null
);
-- profiles: id(=auth.users.id), organization_id, team_id, role app_role,
--   full_name, email, job_title, avatar_seed, employment_status,
--   theme_preference, last_active_at

create or replace function public.org_and_descendants(root uuid)
returns setof uuid language sql stable as $$
  with recursive tree as (
    select id from public.organizations where id = root
    union all
    select o.id from public.organizations o join tree t on o.parent_id = t.id)
  select id from tree; $$;
```

**Content:** `course_categories`, `courses` (28), `enrollments` (powers Library + Matrix), `certificates` (Storage), `course_requirements`.
**Engagement:** `saved_views` (replaces `localStorage`; Realtime-shareable), `notifications`, `ideas`+`idea_votes`, `chat_messages`.
**Admin/platform (new):** `platform_settings`, **`ai_integrations`**, `ai_usage_logs`, `audit_log`.

```sql
create type ai_provider as enum ('anthropic','openai','azure_openai','custom');
create type ai_status   as enum ('unconfigured','connected','error','disabled');
create table public.ai_integrations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations(id),  -- per-operator or platform-wide
  provider ai_provider not null, display_name text not null,
  is_enabled boolean not null default false,
  api_key_cipher text,                 -- encrypted; never returned to the browser
  default_model text, base_url text, options jsonb not null default '{}',
  status ai_status not null default 'unconfigured', last_tested_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.ai_integrations enable row level security;
```

Compliance **views** over `enrollments` keep RAG % consistent. **RLS:** cascading by `org_and_descendants(auth_org_id())`; learners→self; team managers→team; `ai_integrations`/`platform_settings`/`audit_log` admin-only; secret columns server-side only.

---

## 11. Admin → Platform Settings (AI integration)

New **Platform Settings → AI Integrations** page (reusing existing card styling; scoped per operator). A **"Connect Claude AI"** card — Enabled · Display name · Provider (Anthropic preselected) · **API key** (masked, write-only) · Default model · Base URL · **"Test connection"** (server-side). Keys encrypted at rest, decrypted server-side only, never sent to the browser; admin-only RLS; changes audit-logged. Can power the in-app chat; defaults to a demo/mock key.

---

## 12. Rollback strategy

1. **Golden snapshot:** tag **`v0.1-prototype-rollback`**; restore SHA **`07b90c6c33b38d2a9ffb98f5750648ec278dad64`**; local commit **`rollback: pre-improvement baseline v0.1`**; untouched HTML copy kept.
2. **Isolation:** BespokeLMS Laravel in a **new repo** (`BespokeLMS`) — the static Turner Price site & its Netlify deploy are never modified.
3. **Branch-per-phase**, PR-merged after QA.
4. **Database:** new project; reversible migrations (up/down) + `reset.sql` rebuild (mock data).
5. **Deploy:** host history rollback; Netlify static as ultimate fallback.
6. **Written revert runbook.**

---

## 13. Phased execution

| Phase | What happens |
|---|---|
| **0 · Rollback** | Tag `v0.1-prototype-rollback`, freeze branch, untouched copy, new `BespokeLMS` repo |
| **1 · Supabase** | Create `bespokelms` (£0) · org tree + operator subtypes + RBAC + all tables · cascading RLS · mock seed · **7 demo accounts** |
| **2 · Laravel shell** | Scaffold + Tailwind build · tenant routing · **pixel-identical shell**, all breakpoints, light+dark |
| **3 · My workspace** | Dashboard + Library + dark mode + a11y + responsive fixes |
| **4 · Team workspace** | Scope switching · matrix (xl-gated) · saved views → DB + Realtime |
| **5 · Admin + AI + RBAC UI** | Operator-aware admin depth · tenant switcher · demo role switcher · AI Integrations |
| **6 · Responsive & a11y QA** | All breakpoints · light/dark · touch · role/tenant checks · screenshot diffs · audit |
| **7 · Deploy** | Pick host · per-operator URLs · GitHub auto-deploy · Supabase |
| **8 · Flutter (later)** | Same backend |

---

## 14. Open questions (not blocking)

Tenancy URL style (subdomain vs path) · Laravel host (Phase 7) · self-host Lato vs Google Fonts · dark-palette sign-off · per-operator white-label theming scope · Flutter screen priority · demo role-switcher only in non-prod builds.

---

## 15. On approval, I start here

1. **Rollback snapshot** (tag/freeze/copy/new `BespokeLMS` repo).
2. **Confirm £0 Supabase** and create `bespokelms`; apply org tree + operator subtypes + RBAC + schema + seed + 7 demo accounts + RLS.
3. **Scaffold Laravel**, prove **pixel-identical** styling (all breakpoints, light+dark) before any feature.

*Reply with edits — or tell me how you want to start (options in chat).*
