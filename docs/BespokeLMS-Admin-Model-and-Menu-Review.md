# BespokeLMS — Admin model, Marcus Reed login & tenant-management menu

**Review & implementation plan · 22 July 2026**
*Prototype, mock/demo data only. No styling changes. Scope of this pass: seed the tenant admins and report how login + tenant management can be built. The course uploader / CMS is explicitly out of scope for now.*

---

## 1. Headline

The backend is further along than the front end realises. The Supabase project is live and fully seeded, Row-Level Security is on every table, and **all the admin accounts already exist as real, confirmed, password-ready Supabase Auth users — including Marcus Reed**. Nobody has ever logged in (`last_sign_in_at` is null across the board) for one simple reason: **the prototype has no login and no Supabase code at all**. The "identity" you see today is cosmetic.

So the work to "log in as Marcus Reed and see a BespokeLMS admin menu" is almost entirely **front-end wiring**, not database work. That is good news — it means we can move quickly without touching the schema.

One change worth recording: the Supabase MCP connector can now reach the BespokeLMS project (`pqmdtqsscyltykgcwwus`). In the last session it returned *permission denied*; it now has full access, so migrations and seeding can be driven directly from here.

---

## 2. What I did in this pass

FoodComplianceHQ was the only tenant with **no** operator admin. I seeded one to match the other three exactly (real `auth.users` row + email identity + linked `lms_operator_admin` profile, email-confirmed, password set). **All four tenants now have a login-ready admin.**

### Admin roster (live in Supabase now)

| Tenant | Type | Admin persona | Login email | Role (`app_role`) |
|---|---|---|---|---|
| **BespokeLMS** (platform) | platform | **Marcus Reed** — Platform Owner | `kemp.house+bespokelms@…` | `bespokelms_owner` |
| **Turner Price** | operator · reseller | Turner Price Admin | `kemp.house+turnerprice@…` | `lms_operator_admin` |
| **TeachHQ** | operator · own_brand | TeachHQ Admin | `kemp.house+teachhq@…` | `lms_operator_admin` |
| **FoodComplianceHQ** | operator · own_brand | FoodComplianceHQ Admin *(new)* | `kemp.house+foodcompliancehq@…` | `lms_operator_admin` |
| **March Foods** | operator · inhouse | March Foods Admin | `kemp.house+marchfoods@…` | `lms_operator_admin` |

*(Below the operators sit the demo client/team/learner accounts: Chris Bennett — client admin, Sarah Whitfield — team manager, Emma Wilkinson — learner, plus 11 seeded learners, all under All Saints' Catholic Primary within Turner Price.)*

Passwords for the demo accounts are provided in chat (kept out of this doc so it can be committed to the repo safely). I set the new FoodComplianceHQ password and can standardise **all** demo logins to one shared password on request — I can't read the existing ones, only reset them.

---

## 3. The tenant tree (as seeded)

```
BespokeLMS (platform)                    ← Marcus Reed (bespokelms_owner)
├── Turner Price     (operator · reseller,  has_client_layer = true)
│     ├── All Saints' Catholic Primary  (client · school)  ← Chris Bennett, Sarah Whitfield, Emma + 11 learners
│     └── St Mary's Catholic Primary     (client · school)
├── TeachHQ          (operator · own_brand, has_client_layer = true)
│     └── Demo Academy Trust             (client · trust)
├── FoodComplianceHQ (operator · own_brand, has_client_layer = true)   ← no clients seeded yet
└── March Foods      (operator · inhouse,  has_client_layer = false)   ← org IS the client; teams+learners directly
```

The five-tier role model (`bespokelms_owner → lms_operator_admin → client_admin → team_manager → learner`) and the cascading RLS that scopes each tenant to its own subtree are already implemented and enforced.

---

## 4. Your admin capability model, mapped to the schema

You described two tiers of administrator. Here is how each capability lands against what exists today versus what needs adding later (**none of which I'm building now**).

### 4a. BespokeLMS admin (Marcus Reed / platform owner)

| Capability you described | Schema support today | Verdict |
|---|---|---|
| Create a **brand + front end** for the BespokeLMS website | `organizations.brand_theme` (jsonb) exists per-org, incl. the platform row | Brand tokens ✅ · **CMS pages: to add** |
| **Upload and manage all courses** | `courses` table (28 seeded), `course_categories` | ✅ (management UI later) |
| **Cascade courses down to tenants** | `courses.owner_org_id` — **null = platform/"system" catalogue**; a value = tenant-owned | ✅ mechanism exists |

### 4b. Tenant (operator) admins

| Capability you described | Schema support today | Verdict |
|---|---|---|
| Create their **own brand kit + front CMS pages** | `organizations.brand_theme` per operator | Brand tokens ✅ · **CMS pages: to add** |
| **Update their own courses** | `courses.owner_org_id = <their org>` | ✅ |
| **Control visibility of BespokeLMS system courses** | *No per-tenant visibility toggle yet* | **To add** |

### What the model still needs (later — flagged, not built)

Three small additions cover everything above, and none disturb existing data:

1. **Per-tenant course visibility** — a table such as `org_course_settings(organization_id, course_id, is_enabled, sort)`. Platform ("system") courses stay owned by BespokeLMS via `owner_org_id = null`; each operator flips them on/off for their own world without copying them. This is the missing piece behind "control visibility of the system courses."
2. **CMS / front-end pages** — a `cms_pages` table (org-scoped: `organization_id`, `slug`, `title`, `blocks` jsonb, `status`) plus brand assets (logos/hero images) in Supabase Storage. Serves both the BespokeLMS marketing site and each operator's branded front pages.
3. **Brand kit** — mostly a UI over the existing `brand_theme` jsonb (accent colour, logo, font); optionally promote a few fields to real columns once the editor is designed.

The **course uploader itself is not in scope now**, per your instruction — but the cascade + ownership foundations it will rely on are already in place.

---

## 5. Should tenant management be a separate menu? — Yes, and here's why

**I agree with you, strongly.** BespokeLMS tenant management should be its own top-level menu, not a fourth item bolted inside Admin. Four reasons:

**Altitude.** My, Team and Admin all operate *inside a single tenant's world* — a learner's own record, a manager's team, an operator running their own LMS and business. Tenant management operates *across the whole platform*: provisioning the operator tenants themselves, their hierarchy, their branding, the global course catalogue that cascades to them. That's a landlord's job, not a tenant's — a genuinely different mental model, so it deserves a different front door.

**Audience & security.** Only the platform owner (Marcus Reed, `bespokelms_owner`) should ever see tenant management. My/Team/Admin are shared by learners, managers and operator admins. A separate menu that renders **only** for the owner — and is absent from the DOM for everyone else — is cleaner and safer than conditionally hiding a sensitive section inside a menu that operator admins also use.

**The current "Admin" is already a full console.** Today's Admin workspace (confusingly titled "Platform Management" in the sidebar) is a ten-group accordion: Accounts & Contacts, Marketing, Inbox, Billing, Feedback & Updates, Content Management, Reference Data, Integrations, Website & Consent… That's an operator running *their own business*. Dropping "manage all the tenants" as an eleventh accordion group would bury the single most important owner capability inside a business-ops menu.

**It scales with the portfolio.** Four operators today; more later. Cross-tenant work — a portfolio health dashboard, per-operator drill-in, a provisioning wizard, the global catalogue, platform branding, platform AI settings — is a *workspace*, not a menu item.

And it matches the plan already on file: the re-platform plan gives Tier 1 the tab set **`Platform · Admin · Team · My`** — exactly this separation.

### Recommended shape

A **fourth top-level workspace — "Platform"** — owner-only, sitting alongside My / Team / Admin (rendered only when `role = bespokelms_owner`).

| Menu | Who sees it | Scope | Holds |
|---|---|---|---|
| **Platform** *(new)* | Owner only | **Across all tenants** | Tenants/operators list + detail · provision new operator/client · **global course catalogue + cascade** · platform branding & CMS · platform settings + AI integration · cross-tenant reporting · "view as tenant" |
| **Admin** | Owner + operator/client admins | **One tenant** | That tenant's business ops (CRM, marketing, billing, content, integrations) — as today, data-scoped by role |
| **Team** | Managers + admins | One team / scope | Compliance matrix, saved views |
| **My** | Everyone | Self | Learner dashboard + course library |

**The bridge between them:** from **Platform**, Marcus picks a tenant (say Turner Price) and drops into that tenant's **Admin**, scoped to Turner Price — the classic "impersonate / view as tenant" pattern. It keeps Platform about *choosing and configuring* tenants, and Admin about *operating within* one, with a clean hand-off.

One tidy-up worth doing at the same time: the existing Admin sidebar is currently headed "Platform Management," which will now collide with the real Platform menu. Renaming that heading to something tenant-scoped (e.g. "Operator Admin" or "*{Tenant}* Admin") removes the ambiguity. That's a label change, not a restyle.

---

## 6. How "log in as Marcus Reed" gets built

### Where the code is today
- **`switchWorkspace('my'|'team'|'admin')`** toggles three panels (`#ws-my/#ws-team/#ws-admin`); each renders its own My/Team/Admin tab bar.
- **Identity is fake:** an `IDENTITY` map swaps the header chip to "Emma Wilkinson" (My/Team) or "Marcus Reed / Platform Administrator" (Admin). `profileLogout()` is a mock toast. There is **no auth and no Supabase client anywhere** in the 336 KB file.
- Data lives in inline JS arrays (`LIB` courses, `SCOPE`/`SC_DATA` compliance, `MXV` saved views in `localStorage`).

### The wiring (keeps styling identical)
1. **Add the Supabase JS client** (one `<script>` from CDN) with the project URL + publishable/anon key.
2. **Add a login screen** → `supabase.auth.signInWithPassword()`. On success, load the caller's `profiles` row (role + organization).
3. **Render by role, from the DOM up.** Replace the cosmetic identity swap with the real session: `bespokelms_owner` → Platform + Admin + Team + My; `lms_operator_admin` → Admin + Team + My (scoped to their org); `client_admin` → scoped Admin + Team + My; `team_manager` → Team + My; `learner` → My only. Role-forbidden menus are **not emitted**, not merely hidden.
4. **Replace mock arrays with live reads** — the browser talks to Supabase directly under RLS (exactly what the publishable key + RLS are for). No server needed for reads.

This can be done **on the existing static prototype** — styling untouched, still hosted on Netlify — and every line of it (schema, Auth, RLS, queries) carries over unchanged if/when you move to the Laravel build. The only things that *must* wait for a server are the secret-handling bits (decrypting `ai_integrations.api_key_cipher`, custom SMTP) — none of which block login or tenant management.

---

## 7. Replacing dummy data with real data — suggested order

| Phase | What goes live | Reads from |
|---|---|---|
| **A · Real identity** | Login screen + role-gated shell (workspaces render by real role). Marcus logs in, sees **Platform**. | `auth`, `profiles` |
| **B · Tenant management** *(first real-data win)* | The Platform menu's tenant list + health — your four operators with real names, types and compliance %. | `organizations`, `v_org_compliance` |
| **C · Dashboards** | My (Emma's enrolments/library), Team (compliance matrix), Admin headline figures — table by table. | `courses`, `enrollments`, `v_user/team_compliance` |
| **D · Writes** | Saved views move from `localStorage` → DB; notifications; theme preference persists to `profiles`. | `saved_views`, `notifications`, `profiles` |
| **Later (not now)** | Course uploader, per-tenant course visibility, brand-kit editor, CMS pages, Laravel for server-side secrets. | new tables + Storage |

Phase B is the natural first slice: it's the smallest change that turns "manage the four tenants" from mock into real, and it's exactly the menu you asked for.

---

## 8. Security posture (Supabase advisors)

RLS is enabled on **all 17 tables** — no errors. Before real data goes in, three hardening items (all WARN-level):

1. **RBAC helper functions are exposed via RPC.** The seven `SECURITY DEFINER` helpers (`is_admin`, `auth_role`, `org_and_descendants`, etc.) are callable by `anon`/`authenticated` over `/rest/v1/rpc/…`. They're meant to be called *inside* RLS policies, not from the public API — **revoke `EXECUTE` from `anon`** (and ideally `authenticated`). Low risk on a demo (they key off `auth.uid()`), worth doing before production.
2. **Leaked-password protection is off** — one toggle in Auth settings (checks new passwords against HaveIBeenPwned).
3. **Protect the AI key column** — `ai_integrations.api_key_cipher` is currently within an admin's readable columns. When wiring the browser client, exclude it via a safe view or column privileges and keep decryption strictly server-side (Laravel).

*Refs: Supabase database-linter `0028`/`0029` (SECURITY DEFINER exposure) and the password-security guide.*

---

## 9. One open decision

**Which build path for the login + Platform menu?**
- **A — Wire the existing prototype now** *(my recommendation)*: fastest, styling untouched, stays on Netlify, and fully forward-compatible with Laravel.
- **B — Do it inside the Laravel rebuild**: cleaner long-term, but no real login/data until Laravel is scaffolded.
- **C — Wire now, port later**: prove it on the prototype, carry the same Supabase wiring into Laravel when built.

Everything above works the same under A or C; B just defers it.
