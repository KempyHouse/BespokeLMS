# BespokeLMS — Website & Consent Module: Analysis & Implementation Plan

**Date:** 25 July 2026 · **Status:** Proposal for review — nothing applied
**Scope:** Turning "Website & Consent" into the platform's CMS and Consent Management Platform (CMP): multi-surface hosting on custom/vanity domains, a block-based page builder, site menus, web forms wired into the Sales CRM, a Cookiebot-class consent engine with its own scanner, and the support portal + live-chat relocation. Written against the **live** Supabase project `pqmdtqsscyltykgcwwus` (94 public tables + 5 views, migrations through `..._crm_followups_043`) and the `bespokelms-app` Laravel codebase at commit `8a5879f`.

**First asset:** the BespokeLMS marketing site itself — `www.bespokelms.com` as the window onto `app.bespokelms.com`, with `support.bespokelms.com` following.

---

## 1. Where the platform stands (what this module must fit into)

Grounded in the live database and code, not the mock-up.

**Tenancy.** `organizations` is a self-referencing tree (`platform` → `operator` [reseller / inhouse / own_brand] → `client`) with RLS built on SECURITY DEFINER helpers (`auth_org_id()`, `org_and_descendants()`, `is_platform_owner()`). Nine orgs live, BespokeLMS `f8bd0282-…` at the root.

**Navigation is already a CMS.** `RouteRegistry` (code-first, `nav:sync-registry`) → `route_registry` → `nav_menus` / `nav_menu_versions` / `nav_menu_items` / `nav_item_visibility`, rendered by `NavigationResolver` with a 10-minute cache, edited through the Navigation Menu Builder with draft → publish → rollback → diff. **This machinery is 80% of a page builder already** — versions, publishing, role visibility, a diff panel, a code-declared component registry. The Website module should extend it, not clone it.

**Styling is already token-driven end-to-end.** `design_tokens` (platform defaults + `dark_value` + `themeable` flag) merged with `brand_kit_tokens` overrides by `ThemeResolver`, injected as `:root{…}` / `[data-theme='dark']{…}`. `brand_kits.logo_path` / `favicon_path` in the public `branding` bucket, resolved by `App\Support\Branding\BrandAssets`. **Critical consequence:** a tenant's public website and cookie banner can be fully brand-correct with zero hard-coded values, because the token layer already resolves per organisation. It currently resolves from the *signed-in user's* org — for public pages it must resolve from the *hostname*.

**Module gating exists.** `tenant_modules` (mig. 028) + `EnsureModuleEnabled` (`module:sales_crm`, fails closed, 404s rather than 403s). Only `sales_crm` on BespokeLMS is enabled today. New modules plug straight in.

**The CRM is ready to receive web leads.** `crm_record_source` already contains **`web_form`**. `crm_accounts.website_domain` exists (domain-based account matching). `crm_contact_emails`, `crm_contact_phones`, `crm_lifecycle_stage`, `crm_deals` + pipelines, and the mig. 031 auto-link triggers (contact ↔ platform profile by email, inside a legitimate ownership boundary) are all live. A contact-us form has a first-class destination on day one.

**Adjacent machinery to reuse, not duplicate:**

| Existing asset | Reuse in Website & Consent |
|---|---|
| `nav_menus` / versions / items + builder + `NavigationResolver` | Site menus (primary/footer/utility) as new menu types; same publish/rollback/diff |
| `dashboard_widgets` registry + `dashboard_widget_visibility` + `user_dashboards` | Exact precedent for a **block registry**: platform-owned catalogue, per-role visibility, per-instance layout |
| `route_registry` + `nav:sync-registry` | Precedent for code-declares/DB-mirrors — block types get the same treatment |
| `design_tokens` + `brand_kits` + `ThemeResolver` + `BrandAssets` | Public site theming, banner theming, OG images, favicons |
| `outbound_templates` + `BrandedEmailRenderer` + `TenantMailer` + `tenant_email_aliases` + `email_send_logs` | Form autoresponders, internal notifications, all branded per tenant |
| `crm_*` (accounts/contacts/activities/deals) + mig. 031 auto-link | Form submissions → contacts, accounts, timeline, opportunities |
| `content_translations` (`entity_type`/`entity_id`/`locale`/`fields` jsonb) | Page, block and banner copy translation — already generic |
| `boards` / `board_stages` / `work_items` (mig. 008) | Support desk queue; editorial workflow for pages if wanted |
| `audit_log`, `platform.sudo`, `profile_capabilities`, `feature_flags` | Publishing controls, consent config changes, capability grants |
| `<x-data-table>`, `<x-ds-select>`, `<x-pill-switch>`, `<x-nav-breadcrumb>` | Every admin list/edit screen in the module |

---

## 2. Your four questions, answered

### 2.1 "Support Portal should move to Website & Consent" — **yes, but split it three ways**

Your instinct is right and the reason it's right is worth stating precisely, because it generalises: **the platform currently conflates content, surface, and workload.** Those are three different things and they belong in three different places.

| Concern | What it is | Where it belongs | Live today |
|---|---|---|---|
| **Content** | The support articles themselves — authored once, versioned, translated, cascaded to tenants | **Global Content** | `content.support-articles` (planned), `content_type: support_article` |
| **Surface** | `support.bespokelms.com` — the public site that renders those articles, its menus, its search, its contact form, its branding | **Website & Consent** | `ops.support-portal` (planned) — *wrong group* |
| **Workload** | The queue where staff triage and answer tickets, SLAs, assignment, reporting | **Operations** | `ops.support-desk` (planned) — correct where it is |

So: **move `ops.support-portal` → Website & Consent** (it becomes a *site* of surface type `support`, built from the same pages/menus/forms/blocks as any other site). **Leave `ops.support-desk` in Operations.** **Leave `content.support-articles` in Global Content**, and give it a "published to" relationship pointing at the portal site — one article can surface on several tenants' portals.

The same test resolves `ops.knowledge-base` (currently Operations): the knowledge *base* is content; the knowledge base *portal* is a surface. Recommend folding it into `content.support-articles` + the portal, rather than keeping a third planned destination that will overlap both.

### 2.2 "Live Chat should move to Communication" — **yes, and it's the same split**

Live chat is two products wearing one label:

- **The conversation** — an agent inbox, real-time, two-way, with transcripts, routing, availability, canned replies. That is a *channel*, and it sits alongside Email / SMS / WhatsApp / Notifications. → **Communication.**
- **The widget** — where it appears, on which pages, what it looks like, the pre-chat form, offline capture, and (critically) **whether it may load before consent**. That is a *web asset configuration*. → **Website & Consent.**

That is exactly the distinction you drew, and it holds. Two refinements:

1. **The Communication group needs a shape.** It is currently a flat list of `outbound.*` destinations — all *outbound, one-way, templated*. Live chat is inbound and conversational. Recommend two sub-groups inside Communication: **Outbound** (System Emails, Transactional, Marketing, SMS, WhatsApp, Social, Score, Logs) and **Conversations** (Live Chat, Inbox, WhatsApp threads later). Renaming the group is unnecessary; adding the sub-structure is.
2. **One chat engine, three surfaces.** `my.help` is already registered as `type: action, action: openChat` — the in-app help drawer. The same engine should serve (a) the in-app drawer, (b) the marketing-site widget, (c) the support-portal widget. Different surfaces, different pre-chat forms, different consent posture; one conversation store, one agent inbox, and transcripts landing on the CRM timeline for known contacts.

**Schema note:** `crm_activity_type` has `note | call | email | meeting | task | sms | whatsapp | document | system` — **no `chat`**. Adding it is an `ALTER TYPE … ADD VALUE`, which must live in its own migration, separate from first use (the gotcha that bit the nav work).

### 2.3 "Where should the menu builder live?" — **it is already in the right place; give it a surface dimension**

`cms.navigation` ("Navigation Menus") is already under **Website & Consent** in the published `platform-rail` v6. So the answer to "should it be inside Website & Consent?" is: it is, and it should stay — **but the reason it's there today is not the reason you gave, and that gap matters.**

Today the builder manages **application chrome**: `workspace-switcher`, `my-rail`, `team-rail`, `platform-rail`, `crm-subrail`, `app-header`. Those are not website assets — they are the product's own navigation. Your framing ("menus, forms, pages are all components") is about *website* menus, which don't exist yet.

Two options:

- **(a) One builder, two surfaces.** Keep `cms.navigation` where it is. Add `site_primary`, `site_footer`, `site_utility` to `nav_menu_type`, add `website` to `nav_domain`, and filter the builder by surface (an existing pill-switch does this well). One versioning engine, one publish/rollback/diff, one resolver, one set of role-visibility rules.
- **(b) Split it.** "App Navigation" under Platform Workspace, "Site Menus" under Website & Consent.

**Recommend (a).** The builder's hard parts — draft/publish/rollback, version diffing, role visibility, resolver caching — are surface-agnostic and already built and proven. Splitting duplicates all of it. What (a) needs is one genuine schema change, below.

**The one real difference between app menus and site menus.** App menu items point at `route_key` → `route_registry` → a named Laravel route. That is deliberately a *code-first engineering contract*: a tenant cannot invent a destination. Site menu items must point at **tenant-authored pages**, which are data, not code. So `nav_menu_items` needs a polymorphic target:

```
target_type  enum: route | page | url | anchor | file | action     (default 'route')
target_id    uuid  -- web_pages.id when target_type = 'page'
```

`route_key` stays as-is for `route`, so nothing existing changes. The resolver gains one branch. This is the single most important schema decision in the menu question, and it's what makes "menus are components" actually true rather than aspirational.

**Then, yes: reframe Website & Consent as the CMS,** with two sub-groups:

- **Sites** — Sites, Pages, Navigation (menus), Forms, Media, Redirects, Domains
- **Consent** — Cookie Banner, Purposes & Vendors, Cookie Scans, Consent Records, Preference Centre

### 2.4 The rail, before and after

**Now (platform-rail v6, published):**

```
Platform Workspace   Tenants · Platform Settings
Website & Consent    Navigation Menus
Global Content       Courses · Widgets · Learning Pathways · Policies · Resources · Support Articles
Communication        System Emails · Transactional · Marketing · SMS · WhatsApp · Social · Notifications · Score · Logs
Integrations         AI & Voice · Email · Integration Logs
Monitor              Platform Users · Usage & Analytics · Security
Operations           Sales CRM · Marketing · Support Desk · Support Portal · Live Chat · Knowledge Base · Reports
Product Development  Backlog · Sprints · Roadmap · Releases · Bugs / Issues
```

**Proposed:**

```
Platform Workspace   Tenants · Platform Settings
Website & Consent    ── Sites ──      Sites · Pages · Navigation · Forms · Media · Redirects · Domains
                     ── Consent ──    Cookie Banner · Purposes & Vendors · Cookie Scans · Consent Records
Global Content       Courses · Widgets · Learning Pathways · Policies · Resources · Support Articles
Communication        ── Outbound ──      System Emails · Transactional · Marketing · SMS · WhatsApp · Social · Notifications · Score · Logs
                     ── Conversations ── Live Chat · Inbox
Integrations         AI & Voice · Email · Integration Logs
Monitor              Platform Users · Usage & Analytics · Security · Website Analytics
Operations           Sales CRM · Marketing · Support Desk · Reports
Product Development  Backlog · Sprints · Roadmap · Releases · Bugs / Issues
```

Moves: `ops.support-portal` → Website & Consent (as a site). `ops.live-chat` → Communication ▸ Conversations. `ops.knowledge-base` → folded into `content.support-articles` + the portal. Everything else stays.

**These moves are data, not code.** They are drag-and-drop in the menu builder against a draft, then publish. No migration, no deploy. Do them first — see Phase 0.

---

## 3. Challenging the brief

### C1. "Website & Consent" is two products. Name them, phase them, but keep them in one module.

A CMS and a CMP are separable products with different buyers. Bundling them is right for you — the CMS is precisely what makes your CMP better than Cookiebot (§7.4) — but the module must be internally honest about the seam: separate module keys (`website_cms`, `consent`), separate capabilities, separate enablement per tenant. A tenant should be able to buy consent without buying the site builder (they have a WordPress site and want your banner on it), and vice versa. **Recommendation:** two module keys under one menu group, and design the consent engine so its script can be embedded on **any** site, not only sites you host.

### C2. Public pages break the platform's core security assumption. Design for that explicitly.

Every read path in the app today assumes an authenticated Supabase user, and owner consoles use the **service-role key** with route middleware as the authorisation boundary. Public website traffic has neither. Three hard rules:

1. **Tenant identity comes from the hostname and nothing else.** Never a query parameter, never a header, never a cookie. `www.bespokelms.com` → BespokeLMS. Unknown host → **404, never a fallback tenant.** A host-to-tenant mix-up in a white-label product is a brand and data incident simultaneously.
2. **Public reads go through a dedicated reader** (`SupabasePublicSite`) that takes the resolved org + site from the host-resolution middleware, filters on `status = 'published'` *and* `organization_id = :resolved`, and is the only class permitted to read site content without an authenticated user. Same discipline as `CrmScope`; add the same convention test.
3. **No session on the public surface.** Marketing and support pages are anonymous. Do not share the app's session cookie across `app.` and `www.` — scope `SESSION_DOMAIN` to the exact host. The "Log in" button is a link to the app host; that is the entire integration.

### C3. Don't let the CMS become a hole in the design system.

The project rule is absolute: no hard-coded colours, spacing, radii, or breakpoints. A page builder is the single most likely place for that rule to die, because tenants will want a "custom" hero. **Recommendation:** block props may reference **token keys only** — never raw values. The same pattern already used by `board_stages` and `crm_pipeline_stages` (colour stored as a *token key*, validated against seeded keys) applies verbatim. If a tenant needs a value the design system doesn't have, it gets added to `design_tokens` first, as a token, with light and dark values. No raw-HTML block on any tenant tier (your earlier instinct was right to hesitate); if the platform owner needs an escape hatch, gate it behind `platform.sudo` and sanitise on save *and* on render, exactly as `EmailBodySanitiser` does.

### C4. "No dummy data" applies to marketing pages too — which is a feature.

The project instructions forbid mock/sample content. A marketing site is where fabricated content usually creeps in ("300+ courses!"). **Recommendation:** make the headline blocks *data-bound*. A "Course grid" block reads `courses` filtered by `course_catalog_status = 'published'` and territory; a "Stat" block binds to a named metric (course count, tenant count) resolved server-side from the same readers the dashboards use. Marketing copy is authored; **numbers are queried.** This also means the site can never go stale, and it's a genuine differentiator when you demo it.

### C5. Build the CMP; don't resell one. But know exactly why. **[CONFIRMED — no third-party API]**

The research (§7) is unambiguous on the deciding factor: **no vendor in this market sells per-client custom consent domains *and* per-client dashboard branding.** Cookiebot has no provisioning API at all, no RBAC, and treats logo removal as a documented CSS hack. Didomi is the only vendor with a complete `POST /organizations` → notice → `POST /domains` (auto-SSL) chain, and would get you six months earlier if you decided to buy. Since white-label per-tenant identity is the entire premise of BespokeLMS, **build** — and treat the four Cookiebot gaps (provisioning API, RBAC, branding toggle, per-domain billing with a 4× tier cliff) as the product brief. **Decision taken 25 July 2026: recreate the functionality in-house. No Cookiebot API, no Didomi, no reseller arrangement — the vendor comparison below is retained only as a feature checklist to build against.**

### C6. Skip IAB TCF. Say so in writing, once.

TCF v2.3 became mandatory 1 March 2026, costs ~€1,575/year plus Google certification and annual recertification, forces a "1,200 partners" vendor list into your tenants' banners, and carries live litigation risk. Your tenants are B2B LMS operators running GA4, LinkedIn Insight and HubSpot — not RTB participants. **Recommendation:** no TCF in the roadmap; revisit only if a tenant sells programmatic advertising. Record the decision so it isn't relitigated quarterly.

### C7. You will be a **processor** for tenant consent data. That changes the schema, not just the paperwork.

For Turner Price's website visitors, Turner Price is the controller and BespokeLMS is a processor — the same boundary already encoded for CRM data (C2/C3 of the CRM proposal). Consequences: consent records are org-exact (never subtree, and **the platform owner must not be able to read another tenant's consent ledger** through `is_platform_owner()`); export and erasure are per-tenant operations; the DPA must name consent processing explicitly. Note the circularity trap: **the consent log is itself personal-data processing and cannot lawfully be based on consent.** Base it on Art. 6(1)(c) read with Art. 7(1) (or legitimate interests) and record that in the ROPA.

### C8. Prior blocking is the compliance core, and it is where you beat the market — because you own the CMS.

Every runtime CMP intercepts scripts in the browser: Cookiebot rewrites `type="text/javascript"` → `text/plain`, which requires being the **first, synchronous script in `<head>`** (at war with Core Web Vitals), fails open when it doesn't load, and gates entire bundles behind marketing consent. **You render the page.** Third-party embeds can be gated *at render time*, server-side, from the visitor's consent cookie — no request is ever made. That structurally beats every runtime approach and no other vendor can do it for arbitrary customer sites. Design the block registry so that **every block declares the consent purpose it requires**, and the renderer emits either the embed or a token-styled placeholder with a "load this content" affordance.

⚠️ **The unblocking gotcha to encode in the client runtime:** setting `el.type = 'text/javascript'` in place does **not** execute a blocked script — the HTML spec only "prepares" a script element on insertion, on `src` being set while connected, or on children changing. The unblocker must clone attributes onto a fresh `<script>` and re-insert. Same for `<img data-src>` / `<iframe data-src>`: leave `src` unset entirely.

### C9. Don't build the scanner first. Build it third — but design the tables for it now.

A crawler is the moat (nobody OEMs one), but it is also the only part of this module that needs infrastructure the platform doesn't have: headless Chromium, which cannot run on the Laravel Cloud web tier or in a Supabase Edge Function. It needs a container worker. Meanwhile a banner with a **manually curated** cookie declaration is 100% compliant and ships in weeks. **Recommendation:** phase the scanner after the banner, but create `observed_*` and `cookie_classifications` in the same migration family so the declaration UI is scanner-shaped from day one.

### C10. Consent for anonymous visitors — pseudonymous ledger, stitched on identification.

You asked what to do about storing cookie preferences when the visitor isn't a known user. Do **not** create a CRM contact for an anonymous visitor (fabricating a record from a cookie choice is both bad data and questionable purpose limitation). Instead:

- Every visitor gets a `consent_id` — a random pseudonymous UUID stored in a first-party, strictly-necessary cookie. All consent records key on it.
- When the visitor becomes identified — submits a form, clicks a tracked link, signs into the LMS — the `consent_id` is attached to the `crm_contacts` row (`consent_id` column) and, from that moment, their consent history is visible on the CRM timeline. Historic records are stitched by `consent_id`, not copied.
- Marketing consent captured **on a form** is a different legal object from cookie consent and gets its own purpose and record. Keep them separate rows in one ledger, distinguished by `collection_method` and `purpose`.
- **Minimise.** Store a derived `country` and discard the IP, or truncate/salted-hash it. Full IP collected solely to prove consent is the classic over-collection trap and it is what got Cookiebot enjoined in Germany (VG Wiesbaden, 2021 — later overturned on procedural grounds only, so treat it as unresolved rather than settled).

### C11. Set stricter defaults than the market, deliberately.

6-month consent lifetime, **symmetric for accept and reject**, with immediate re-prompt when the banner config or vendor list changes. That aligns with both CNIL's consolidated recommendation and the ICO's April 2026 guidance, and it is stricter than the 90-day and 12-month defaults competitors ship. Proof retention runs on a different clock: processing duration **plus the limitation period** (6 years in the UK), held in your own Supabase store — not the 12 months Cookiebot erases at. Three clocks, never conflated: consent lifetime, tracker lifetime, proof retention.

---

## 4. The surface model, and custom / vanity domains

### 4.1 Concept

One Laravel application serves several **surfaces**. A surface is decided by hostname, before authentication:

| Surface | Example | Auth | Renderer |
|---|---|---|---|
| `app` | `app.bespokelms.com`, `tp.bespokelms.com` | Required | Existing authenticated app |
| `marketing` | `www.bespokelms.com`, `bespokelms.com` | Anonymous | Public CMS renderer |
| `support` | `support.bespokelms.com` | Anonymous (+ optional sign-in for tickets) | Public CMS renderer, portal template |
| `consent` | `consent.bespokelms.com` (later, per-tenant) | Anonymous | Banner script + declaration + preference centre |

### 4.2 Schema — `tenant_domains` (mig. 044)

```sql
create table tenant_domains (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid not null references organizations(id) on delete cascade,
  hostname          text not null,                    -- 'www.bespokelms.com', stored lowercased
  surface           domain_surface not null,          -- app | marketing | support | consent
  site_id           uuid null references web_sites(id) on delete set null,
  is_primary        boolean not null default false,   -- canonical host for this surface
  redirect_to_id    uuid null references tenant_domains(id),  -- apex -> www
  verification_token text not null,                   -- TXT _bespokelms-verify.<host>
  verified_at       timestamptz,
  ssl_status        text not null default 'pending',  -- pending|issued|failed
  notes             text,
  created_by        uuid references profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);
create unique index on tenant_domains (lower(hostname));
create unique index on tenant_domains (organization_id, surface) where is_primary;
```

- `hostname` is globally unique, case-insensitively — **the whole isolation model rests on this constraint.** (`citext` is *not* installed on the project; `pg_trgm` is. Use a functional unique index on `lower(hostname)` and normalise on write rather than adding an extension for one column.)
- RLS: readable by the owning org; writable only by platform owner + `platform.sudo` (a domain change can hijack a tenant's traffic; it is the most sensitive write in the module).
- Verification: tenant adds `CNAME <host> → ingress.bespokelms.com` plus `TXT _bespokelms-verify.<host> = <token>`; a console action re-checks and stamps `verified_at`. **Never route a host that isn't verified** — unverified custom domains are a classic subdomain-takeover vector.

### 4.3 Host resolution

New middleware `ResolveHost`, prepended to the `web` group (before `auth`):

1. Normalise the `Host` header (lowercase, strip port, punycode).
2. Look up `tenant_domains` (cached 10 min, `domain:{host}`; the same cache discipline as `NavigationResolver`).
3. Unknown → **404**. Known but unverified → 404. Known with `redirect_to_id` → 301.
4. Bind a `ResolvedHost` value object into the container: `{organization_id, surface, site_id, hostname, locale_default}`.
5. Set the theme context from `organization_id` (so `ThemeResolver` works with no signed-in user), the brand assets, and the locale.
6. Dispatch: `surface = app` → the existing route file; `marketing|support` → `routes/site.php`; `consent` → `routes/consent.php`.

`ThemeResolver::resolve()` already accepts a nullable org id — it needs no change beyond being called with the *resolved* org rather than the user's. That is a one-line change in the layout composer and is the moment the whole white-label story starts working publicly.

**Local/dev:** allow a `*.localhost` and a `?__host=` override **only** when `app.debug` is true, and assert that in a test. This is exactly the kind of convenience that leaks into production.

### 4.4 The BespokeLMS domain map (first tenant)

| Host | Surface | Today | Target |
|---|---|---|---|
| `bespokelms.com` | marketing | Namecheap DNS, Netlify coming-soon | 301 → `www` |
| `www.bespokelms.com` | marketing | dead CNAME → `bespokelms.netlify.app` | Laravel Cloud, CMS-rendered |
| `app.bespokelms.com` | app | not routed | Laravel Cloud, the LMS |
| `support.bespokelms.com` | support | CNAME → Freshdesk | Phase 6 — cut over from Freshdesk |
| `send.bespokelms.com` | email | Resend (DKIM/SPF/DMARC pending) | unchanged |

DNS authority is **Namecheap** (`dns1/dns2.registrar-servers.com`) — Netlify's "already on Netlify DNS" message is misleading; every record goes in Namecheap → Advanced DNS. Leave the Freshworks, Google-verification and existing Freshdesk records alone until Phase 6.

⚠️ **Sequencing that matters:** stand up `app.bespokelms.com` on Laravel Cloud and prove sign-in **before** repointing `www`. The current coming-soon page's login modal redirects to a hard-coded Netlify URL; that string must be repointed at the same time or the front door breaks.

---

## 5. The CMS — schema and model

Migration family **044–049**.

⚠️ **Migration numbering — check before you write.** A parallel session applied `039` (nav org-scoped currency), `040` (`crm_account_brands`), `041`/`041b` (Freshsales import: `crm_import_connections`, `crm_import_runs`), `042` (deal brand) and `043` (CRM follow-ups, `crm_activity_collaborators`) **today**. The next free number is **044**, but run `list_migrations` immediately before writing anything — this repo has two agents in it.

### 5.1 Sites and pages

```sql
create type site_surface as enum ('marketing','support','portal','landing');
create type page_state   as enum ('draft','scheduled','published','archived');

create table web_sites (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  key text not null,                       -- 'bespokelms-marketing'
  name text not null,
  surface site_surface not null,
  default_locale text not null default 'en',
  locales text[] not null default '{en}',
  home_page_id uuid,                       -- FK added after web_pages
  brand_kit_id uuid references brand_kits(id),
  status text not null default 'draft',    -- draft|live|offline
  settings jsonb not null default '{}',    -- analytics ids, robots, social handles
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, key)
);

create table web_pages (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references web_sites(id) on delete cascade,
  organization_id uuid not null,           -- denormalised for org-exact RLS
  parent_id uuid references web_pages(id) on delete set null,
  slug text not null,                      -- 'pricing'
  path text not null,                      -- '/product/pricing' materialised
  title text not null,
  template text not null default 'standard',
  state page_state not null default 'draft',
  published_version_id uuid,
  publish_at timestamptz,
  -- SEO
  meta_title text, meta_description text,
  og_image_path text, canonical_url text,
  noindex boolean not null default false,
  sitemap_priority numeric(2,1) default 0.5,
  sort_order integer not null default 0,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (site_id, path)
);

create table web_page_versions (
  id uuid primary key default gen_random_uuid(),
  page_id uuid not null references web_pages(id) on delete cascade,
  version_no integer not null,
  state version_status not null default 'draft',   -- reuse existing enum
  created_by uuid references profiles(id),
  published_by uuid references profiles(id),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (page_id, version_no)
);

create table web_blocks (
  id uuid primary key default gen_random_uuid(),
  version_id uuid not null references web_page_versions(id) on delete cascade,
  parent_id uuid references web_blocks(id) on delete cascade,   -- columns/sections
  block_key text not null references web_block_types(key),
  sort_order integer not null default 0,
  visible boolean not null default true,
  props jsonb not null default '{}',
  requires_purpose text references consent_purposes(key),        -- C8: render-time gating
  created_at timestamptz not null default now()
);
```

Deliberate mirroring of `nav_menus / nav_menu_versions / nav_menu_items`: same draft → publish → rollback → diff lifecycle, same mental model for the developer and the user, and the builder's diff panel logic is largely transferable.

### 5.2 The block registry — code declares, the database mirrors

Exactly the `route_registry` + `dashboard_widgets` pattern.

```sql
create table web_block_types (
  key text primary key,                    -- 'hero', 'course-grid', 'form-embed'
  label text not null,
  category text not null,                  -- layout|content|media|data|commerce|embed
  description text,
  icon text,
  schema jsonb not null,                   -- prop contract: types, enums, token keys, required
  allowed_surfaces site_surface[] not null default '{marketing,support,portal,landing}',
  status widget_status not null default 'active',
  min_role app_role,
  requires_module text,                    -- e.g. 'sales_crm' for form-embed
  requires_purpose text,                   -- default consent purpose for embeds
  is_data_bound boolean not null default false,
  sort_order integer not null default 0,
  synced_at timestamptz
);
create table web_block_type_visibility ( block_key text, role app_role, primary key (block_key, role) );
```

Declared in `App\Support\Website\BlockRegistry` and mirrored by `php artisan web:sync-blocks` — one entry per block, per the `nav:sync-registry` precedent, so adding a block is one code change plus a sync.

**Launch block set (v1):**

| Category | Blocks |
|---|---|
| Layout | Section, Columns (2/3/4), Spacer, Divider |
| Content | Heading, Rich text, Feature list, Accordion / FAQ, Quote / Testimonial, Logo strip, CTA banner |
| Media | Image, Gallery, Video (consent-gated), Icon |
| Data-bound | **Course grid**, **Course detail**, **Stat tile**, Pricing table (from `v_course_effective_pricing`), Support-article list, Latest posts |
| Forms | Form embed |
| Consent | Cookie declaration table, Consent preference centre, Consent state panel |
| Embed | Map, Calendar/booking, Chat widget, Custom embed (owner-only, sanitised) |

Accessibility is enforced *by the registry*, not by review: `image` requires `alt`; `heading` exposes a level that the renderer validates for document order; every interactive block ships keyboard handling; colours are token keys so contrast is inherited from the design system. This is how WCAG 2.2 AA survives contact with tenants.

### 5.3 Forms — and the CRM link you asked for

```sql
create table web_forms (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  site_id uuid references web_sites(id) on delete cascade,
  key text not null, name text not null,
  submit_label text not null default 'Send',
  success_mode text not null default 'message',   -- message|redirect
  success_message text, success_url text,
  -- CRM wiring
  crm_enabled boolean not null default true,
  crm_lifecycle_stage crm_lifecycle_stage not null default 'lead',
  crm_owner_profile_id uuid references profiles(id),
  crm_create_deal boolean not null default false,
  crm_pipeline_id uuid references crm_pipelines(id),
  crm_source_detail text,                          -- 'Contact us — /contact'
  -- Notifications
  notify_profile_ids uuid[],
  notify_template_key text,                        -- outbound_templates
  autoresponder_template_key text,
  -- Anti-spam
  honeypot_enabled boolean not null default true,
  captcha_provider text, min_fill_seconds integer default 3,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, key)
);

create table web_form_fields (
  id uuid primary key default gen_random_uuid(),
  form_id uuid not null references web_forms(id) on delete cascade,
  key text not null, label text not null, help_text text,
  field_type text not null,      -- text|email|tel|textarea|select|checkbox|radio|date|file|consent|hidden
  required boolean not null default false,
  options jsonb, validation jsonb,
  crm_target text,               -- 'contact.first_name' | 'account.name' | 'account.website_domain' | 'custom'
  consent_purpose_key text references consent_purposes(key),   -- for field_type='consent'
  sort_order integer not null default 0,
  unique (form_id, key)
);

create table web_form_submissions (
  id uuid primary key default gen_random_uuid(),
  form_id uuid not null references web_forms(id) on delete cascade,
  organization_id uuid not null,
  payload jsonb not null,
  submitted_at timestamptz not null default now(),
  page_path text, referrer_path text,
  locale text, country text,                    -- derived; IP not stored
  consent_id uuid,                              -- links the visitor's consent ledger
  status text not null default 'new',           -- new|linked|spam|archived
  crm_contact_id uuid references crm_contacts(id) on delete set null,
  crm_account_id uuid references crm_accounts(id) on delete set null,
  crm_activity_id uuid references crm_activities(id) on delete set null,
  crm_deal_id uuid references crm_deals(id) on delete set null,
  error text
);
```

**Submission pipeline** (`App\Support\Website\SubmitsWebForm`, one transactional path):

1. Validate (Form Request built from `web_form_fields`), honeypot, min-fill time, rate limit per IP+form.
2. Persist the submission — **always, even if CRM linking fails.** A lead must never be lost to a downstream error.
3. If `crm_enabled`: match a contact within the owning org by email (`crm_contacts.email` + `crm_contact_emails`); match an account by `website_domain` derived from the email domain (skipping free-mail domains); create what's missing with `source = 'web_form'` and `source_detail` from the form. **Org-exact — never cross-tenant.**
4. Write a `crm_activities` row (`type: note` today, `type: form` after the enum migration; `direction: inbound`; `source: web_form`) anchored to contact + account, so it lands on the timeline the CRM already renders.
5. Optionally create a `crm_deals` row on the configured pipeline's first stage.
6. Attach the consent record(s) captured on the form, and stitch the visitor's `consent_id` onto the contact (C10).
7. Fire notifications: internal via `outbound_templates` + `TenantMailer`; autoresponder to the submitter, branded, with the tamper-proof legal footer.
8. Honour `crm_contacts.do_not_contact` — an autoresponder to a suppressed address is a compliance incident.

Note that mig. 031's triggers then do their own work for free: if that email matches a platform profile inside the ownership boundary, the contact auto-links and "Became a platform user" appears on the timeline. **A contact-us form on the marketing site therefore produces a CRM contact, an account, a timeline entry, an owner notification, a branded autoresponse, a consent record, and — when relevant — an automatic platform-user link, with no bespoke integration code.**

### 5.4 Media and redirects

```sql
create table web_media (id, organization_id, site_id, path, filename, mime, bytes,
                        width, height, alt_text, focal_point jsonb, uploaded_by, created_at);
create table web_redirects (id, site_id, organization_id, from_path, to_path,
                            status_code smallint default 301, hit_count, last_hit_at);
```

New public storage bucket `web-media`, org-prefixed paths (`{org_id}/{site_id}/…`), the same `pathInScope` discipline `SupabaseCrmDocuments` already uses. `alt_text` is **required at upload**, not optional — the cheapest accessibility win available.

### 5.5 Rendering, caching, SEO

- `SiteController@show` resolves `path` → page → published version → blocks → renders `resources/views/site/layouts/{template}`.
- Blocks render as Blade components `resources/views/site/blocks/{key}.blade.php`, props validated against the registry schema. ⚠️ Observe the known Blade gotchas: no glued `@endif`, no complex closures inside inline `@php(...)`, no directive tokens inside Blade comments.
- Cache the rendered block tree per `(page_id, version_id, locale)`; bust on publish. Publish also flushes the nav resolver cache when a site menu changed.
- Generated per site: `/sitemap.xml`, `/robots.txt`, JSON-LD (`Organization`, `Course` on course pages — real structured data from real course rows), Open Graph from `og_image_path` falling back to the brand kit.
- Mobile-first responsive: blocks use token breakpoints only. Where a block genuinely doesn't work small (a comparison matrix), it degrades to a documented alternative — never a cramped table.

---

## 6. Consent — the CMP

> **Superseded and expanded.** This section is now the summary only. The full engineering spec is `BespokeLMS-Consent-CMP-Build-Spec.md`, written after two scope decisions were taken: the consent engine **must run on tenants' external sites as well as CMS-hosted ones** (an embeddable script, full Cookiebot parity), and **geo rulesets and multi-language are in v1**. Migration family **050–056**; phases C1–C7.

### 6.1 Purposes, vendors, cookies

```sql
create type consent_category as enum ('necessary','functional','analytics','marketing','personalisation');

create table consent_purposes (
  key text primary key,                       -- global keys; tenants may add scoped ones
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform default
  name text not null, description text not null,
  category consent_category not null,
  is_required boolean not null default false, -- 'necessary' only
  opt_out_basis boolean not null default false,  -- UK PECR Sch A1 analytics/appearance
  sort_order integer not null default 0
);

create table consent_vendors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  name text not null, privacy_url text, description text,
  category consent_category not null,
  purposes text[] not null default '{}',
  is_third_party boolean not null default true,
  cookie_patterns text[],                     -- names/domains this vendor sets
  status text not null default 'active'
);
```

**Named third parties with per-party control is a hard regulator requirement** (ICO 2026; CNIL SAN-2025-005), so vendors are first-class, not a text field on the banner.

### 6.2 Banner configuration — versioned, token-styled, hashed

```sql
create table consent_banner_configs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  site_id uuid references web_sites(id) on delete cascade,
  version_no integer not null,
  state version_status not null default 'draft',
  layout text not null default 'dialog',      -- dialog|bar-bottom|bar-top|corner
  position text, show_overlay boolean default true,
  -- styling: TOKEN KEYS ONLY (C3)
  style jsonb not null default '{}',          -- {"surface":"--color-surface","accent":"--color-brand-primary",...}
  copy jsonb not null default '{}',           -- per-locale: title, body, buttons, links
  purposes text[] not null,                   -- which purposes this banner offers
  geo_rules jsonb not null default '{}',      -- region -> ruleset (gdpr|uk|ccpa|none)
  consent_lifetime_days integer not null default 180,   -- C11: 6 months, symmetric
  reprompt_on_config_change boolean not null default true,
  config_hash text not null,                  -- interface provenance
  screenshot_path text,                       -- rendered proof, per version
  published_by uuid references profiles(id),
  published_at timestamptz,
  unique (site_id, version_no)
);
```

**Enforced by the builder, not by guidance** — these are non-negotiable and should be impossible to switch off:

1. **Reject-all on the first layer**, same layer, same click count as Accept.
2. **Equal prominence** — same size, format and legibility; both are buttons, never a buried link.
3. **No pre-ticked toggles** anywhere, including the second layer.
4. **Granular per purpose**, no bundling.
5. **Withdrawal as easy as consent** — a persistent preference-centre entry point.
6. **Nothing fires before consent** (§6.5).
7. No cookie walls; no legitimate-interest tab for advertising trackers.
8. Keyboard operable, focus-trapped, `role="dialog"`, `aria-modal`, screen-reader announced, 44px targets, contrast from tokens. WCAG 2.2 AA applies to the banner *especially* — it is the first thing every visitor meets.

Because styling is token keys and copy is per-locale jsonb, a tenant genuinely cannot build a dark-pattern banner. That is a selling point, not a limitation.

### 6.3 The consent ledger

```sql
create table consent_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  site_id uuid references web_sites(id) on delete set null,
  consent_id uuid not null,                    -- pseudonymous visitor anchor
  domain text not null,                        -- proves scope; critical multi-tenant
  occurred_at timestamptz not null default now(),   -- UTC, ISO-8601 on export
  action text not null,                        -- accept_all|reject_all|save_preferences|withdraw|renew
  purposes jsonb not null,                     -- {"analytics":true,"marketing":false,...}
  vendors jsonb,                               -- per-vendor states where named
  collection_method text not null,             -- banner|preference_centre|form|api|in_app
  banner_config_id uuid references consent_banner_configs(id),
  banner_config_hash text not null,            -- survives config deletion
  policy_version text,
  locale text, country text,                   -- derived at collection; IP discarded
  regulation text not null,                    -- uk_gdpr|gdpr|ccpa
  user_agent_family text,                      -- coarsened, optional
  expires_at timestamptz not null,             -- occurred_at + lifetime
  crm_contact_id uuid references crm_contacts(id) on delete set null,
  profile_id uuid references profiles(id) on delete set null
);
-- append-only: no UPDATE/DELETE policy; withdrawal is a NEW row
```

Design principle from the research, and the one most CMPs get backwards: **prove the interface comprehensively and the individual event minimally.** Interface provenance (config hash + screenshot + version, containing no personal data) is held once per version and kept indefinitely. Each event stores a pseudonymous id, a timestamp, the choices, and a pointer to the interface version. The 2025 Shein and Google decisions turned on interface behaviour, not per-user logs.

Withdrawal must also *work*: stop the technologies, expire the cookies, notify named third parties where feasible, and treat withdrawal as a deletion request for data held under that consent.

### 6.4 CRM integration (your requirement: "consent stored in the Sales CRM")

- `crm_contacts` gains `consent_id uuid` + `consent_updated_at`.
- A **Consent card** on the contact page: current state per purpose, when, from which domain, by which method, with the full history behind it.
- Consent changes write a `crm_activities` row (`type: consent` after the enum migration, `source: web_form`/`sync`), so the timeline tells the whole story: "Submitted Contact us · Consented to analytics, declined marketing · Became a platform user".
- **Marketing eligibility for outbound comes from the ledger, not a checkbox on the contact.** The Communication module asks one question — `ConsentGate::allows($contact, 'marketing')` — and the answer is evidenced. This is the single most valuable integration in the module and the reason to do it in-house rather than resell.
- Erasure: deleting a contact detaches (not deletes) consent records — the proof survives pseudonymously, which is exactly what accountability requires.

### 6.5 Prior blocking, and Google Consent Mode

Three layers, in priority order:

1. **Render-time gating (your advantage).** Blocks declaring `requires_purpose` render a token-styled placeholder unless the server-side consent cookie grants it. No request is made. Covers embeds, maps, video, chat, and any tag a tenant adds through the CMS.
2. **Tag manager gating** for tenants using GTM: tags configured with "require additional consent" genuinely do not fire. Ship a documented GTM template.
3. **Client runtime** for the residue (`type="text/plain"` rewriting, with correct clone-and-reinsert unblocking per C8), plus stripping `preconnect`/`dns-prefetch` hints to non-consented hosts — a `preconnect` to `google-analytics.com` leaks the visitor's IP at TLS SNI time before any script runs, and almost no CMP handles it.

**Google Consent Mode v2** signals (`ad_storage`, `analytics_storage`, `ad_user_data`, `ad_personalization`, plus `functionality_storage` / `personalization_storage` / `security_storage`) are emitted as a *signalling layer behind* prior blocking, defaulting to denied and updating on choice. Position honestly with tenants: advanced Consent Mode alone, without prior blocking, is in our assessment not compliant with PECR reg 6 / Art. 5(3) — and combining advanced mode with real prior blocking removes most of the modelling benefit that motivates advanced mode. That is a commercial trade-off dressed as a technical one, and tenants should make it knowingly. Also support Global Privacy Control as an automatic opt-out signal.

### 6.6 The scanner (Phase 5)

Four stages: **URL discovery → instrumented headless load → state extraction → classification.**

```sql
create table cookie_scans (id, organization_id, site_id, root_url, state, scenario_set,
                           started_at, finished_at, pages_scanned, error);
create table scan_pages (id, scan_id, url, status_code, load_ms, screenshot_path);
create table observed_cookies (id, scan_id, page_id, name, domain, path, expires_days,
                               http_only, secure, same_site, party, scenario,
                               setter_request_id, setter_stack jsonb, first_seen_at);
create table observed_storage (id, scan_id, page_id, kind, key, size_bytes, scenario);
create table observed_requests (id, scan_id, page_id, url_host, url_path, resource_type,
                                initiator jsonb, scenario);   -- partition by month
create table cookie_classifications (name_pattern, domain_pattern, vendor, category,
                                     purpose, retention, confidence, source, evidence jsonb);  -- GLOBAL
create table tenant_cookie_overrides (organization_id, name_pattern, domain_pattern,
                                      category, purpose, note);  -- always wins
```

- `cookie_classifications` is **global, not per-tenant** — the only table in the module without an org column, and the one that compounds in value across every tenant scan. It is the product.
- Bootstrap it from permissively-licensed sources only: **Open Cookie Database** (Apache-2.0, ~2,264 cookies, ships an EDPB-format export), **badger-sett** (MIT), **Brave adblock-lists** (MPL-2.0), **EasyPrivacy** (take the CC BY-SA branch), and the **CookieBlock Zenodo corpus** (CC-BY-4.0, 304k labelled cookies — commercial retraining permitted with attribution). ⚠️ **Explicitly excluded:** DuckDuckGo Tracker Radar, Disconnect, Ghostery trackerdb (all CC BY-**NC**-SA) and cookiedatabase.org (CC BY-NC-**ND**, and API-gated since 1 June 2026). Cookiepedia is OneTrust's and is off-limits. Record these licence decisions in the repo — this is the kind of thing that surfaces during due diligence.
- The unknown tail is classified by LLM (the AI integration layer already exists: `ai_integrations`, `ai_usage_logs`) and cached globally with a confidence score and evidence.
- **Multi-scenario is what makes the report worth paying for:** load with no interaction, with reject-all, and with accept-all. The headline findings from the literature — 82.5% of sites have undeclared cookies, 69.7% set non-necessary cookies before any interaction, **21.3% set cookies despite rejection** — are only detectable this way, and they are exactly the violations a tenant will pay to be told about.
- **Diff against the previous scan and alert on new cookies.** "Your marketing team added Hotjar last Tuesday and it's firing before consent" is the renewal feature.
- Infrastructure: Playwright/CDP in a container worker (Cloudflare Browser Rendering or Browserbase to start at zero ops; AWS Fargate at ~£0.11/1,000 page-loads past roughly 500k/month). ⚠️ **Not** the HTML-rendering scraper APIs — you need a real CDP session for the full cookie jar, initiator chains and re-runnable consent states. ⚠️ Browserless is SSPL/commercial and unsuitable; Steel Browser (Apache-2.0) is the licence-clean self-host option. Bot protection is solved by an **allowlist** (documented static egress IPs + an `X-CMP-Scanner` token at onboarding), not a proxy arms race. Scan from a UK/EU vantage point or you'll capture the US banner variant.

---

## 7. Market position — what we're building against

Condensed from a full competitive study; the detail sits behind this summary.

### 7.1 Cookiebot in one paragraph

Cookiebot (Cybot, merged into Usercentrics 2021) is the SMB self-serve line: monthly domain scanning (daily is a €99/month add-on), an auto-updating declaration table, a Swift banner with Premium-gated custom colours, a 12-month consent log downloadable only as CSV, Google Consent Mode v2 on every tier, TCF v2.3, `data-blockingmode="auto"`, geo-targeting via domain groups, ~46 template languages. **$8–$96 per domain per month**, every domain and subdomain billed separately with no volume discount and a documented 4× cliff between tiers. Reseller terms: 40% for three years then 20% (retail), or 20% wholesale.

### 7.2 The four gaps that are the product brief

1. **No provisioning API.** Verified across the developer page, the API support section (two read-only endpoints, static key in the URL path), the domain-groups docs and the entire ~40-article Reseller Program category. Onboarding is by invite link, one customer at a time. An agency cannot create a Cookiebot tenant from code.
2. **No RBAC, no team accounts.** Credential sharing is the documented workaround. Three separate logins (`admin.` / `manage.` / Usercentrics Admin) is a live merger artefact.
3. **Branding removal is a CSS hack** — Cookiebot publishes an article telling you to `display:none` its own logo elements. A per-tenant toggle is a trivial differentiator.
4. **Auto-blocking is fragile.** Must be the first synchronous script in `<head>`; bundles are all-or-nothing (a `bundle.js` needing marketing consent gates your whole app); `document.write` unsupported; fails open. Cookiebot's own remedy is "switch to manual blocking".

### 7.3 Competitors, filtered to what matters here

| Product | Sub-accounts | White-label **dashboard** | Provisioning API | Published reseller margin |
|---|---|---|---|---|
| **Didomi** | Yes (`POST /organizations`) | No (banner + custom domain) | **Yes — full chain incl. per-client domain with auto-SSL** | 20% recurring / 3 yrs |
| **consentmanager.net** | Yes | **Yes — incl. admin area via reverse proxy** | Yes | Not published |
| **Clym** | **Yes — Instance→Merchant→Domain→Subdomain→Property** | Partial (DSAR admin explicitly not) | **Yes — richest; 200 merchants/request** | Not published |
| **Cookie Script** | Yes | **Yes — own domain via CNAME, logo, colours, emails** | Yes | None ("same prices") |
| **Usercentrics / Cookiebot** | Corporate only | Claimed via a non-public Partner API | Partner API, docs gated | 40%/3yr then 20% |
| **Termly** | Yes | No | Yes (`POST /v1/websites`, bulk) | from 50% off retail |
| **CookieYes** | Agency platform | No | **No** | Agency up to 50% off |
| **iubenda** | **No client logins** (own docs: "in progress") | No | Policies only | 5–10% |
| **Osano / OneTrust / TrustArc / Ketch** | Varies | No / unverified | Configs yes, tenants no | Nothing published |

Be sceptical of "white-label" in this market: for most vendors it means removing a logo from a banner. **Clym's data model is the one to lift** (it maps onto Laravel tenancy and Supabase RLS almost directly). **Cookie Script's packaging is the one to copy** — base plan + per-domain increment + a flat annual white-label add-on tied to a CNAME, the only model that charges separately for the genuinely expensive thing.

### 7.4 Where BespokeLMS wins

1. **Render-time prior blocking.** The most reliable blocking mechanism in the market is server-side, and it is only available to vendors that own the CMS. Complianz-on-WordPress is the sole precedent. Nobody can do it for arbitrary customer sites; **you can do it for every site you host.**
2. **CRM-native consent.** No CMP writes consent to your CRM contact and gates your marketing sends on it. Ours does, because both live in the same database.
3. **Per-tenant everything** — dashboard branding, banner branding, consent-script domain, sender identity, tokens. Nobody offers per-*client* dashboard branding at all.
4. **Provisioning from code**, because the tenants already exist in `organizations`. Creating a tenant's CMP is a row, not a sales call.
5. **Stricter defaults than the market** — 6-month symmetric lifetime, proof retention on a limitation-period clock, multi-scenario scanning.

---

## 8. Touchpoints with the rest of the platform

You asked for all of them. This is the map; each row is a real coupling with a named contract.

| Module | Touchpoint | Contract |
|---|---|---|
| **Sales CRM** | Form submissions → contact/account/activity/deal; consent on the contact record; marketing eligibility | `SubmitsWebForm` → `RecordsCrmActivity`; `ConsentGate::allows()`; `source = 'web_form'` |
| **CRM auto-link (031)** | Web lead that matches a platform profile links automatically and posts "Became a platform user" | Existing DB triggers — free, no new code |
| **Design tokens / brand kits** | Public site, banner, emails all reskin per tenant | `ThemeResolver::resolve($resolvedOrg)`; block/banner styling = token **keys** only |
| **Brand assets** | Site logo, favicon, default OG image | `BrandAssets` + `branding` bucket, already live |
| **Navigation builder** | Site menus as new menu types; polymorphic `target_type`/`target_id` | Same versions/publish/rollback/diff; `NavigationResolver` gains a `page` branch |
| **Route registry** | New destinations for every new page in the module | One `RouteRegistry` entry each + `nav:sync-registry` |
| **Global Content — courses** | Course grid / course detail / pricing blocks on marketing sites; public catalogue | Reads `courses`, `course_categories`, `course_territories`, `v_course_effective_pricing`; needs a `public` visibility flag (D4) |
| **Global Content — support articles** | Portal renders articles; article → portal publication mapping | `content.support-articles` + `web_pages` of template `article` |
| **Widget library / dashboards** | Precedent for the block registry; new widgets: form submissions, consent opt-in rate, scan findings | `dashboard_widgets` + `dashboard_widget_visibility` |
| **Outbound / email** | Autoresponders, internal notifications, marketing sends gated on consent | `outbound_templates` + `BrandedEmailRenderer` + `TenantMailer` + `tenant_email_aliases`; `email_send_logs` |
| **Live chat** | Widget config here, conversations in Communication, transcripts on the CRM timeline | Shared chat engine; `crm_activity_type` gains `chat` |
| **Work management (008)** | Support-desk tickets from portal forms; optional editorial workflow for pages | `boards` / `board_stages` / `work_items`; `work_item_subjects` gains `page`/`ticket` |
| **Change management (009)** | Legal pages (privacy, cookies, terms) under change control with approval | `change_records` separation-of-duties already built |
| **Tenant modules (028)** | `website_cms`, `consent`, `support_portal`, `live_chat` | `EnsureModuleEnabled`, fails closed, 404s |
| **Capabilities / RBAC** | `website`, `website_publish`, `consent`, `consent_export` | `profile_capabilities` + Gate; publish adds `platform.sudo` |
| **Audit log** | Every publish, rollback, domain change, banner change, consent export | `WritesAuditLog`, resolved via `app()` (the shared-instance DI collision) |
| **Search** | Pages, forms, submissions as search groups | `SearchController@suggest`, permission-aware groups |
| **i18n** | Page, block and banner copy translation | `content_translations` (`entity_type`, `entity_id`, `locale`, `fields`) — already generic; `Locales` + `SetLocale` |
| **Saved views** | Filtered submission and consent-record lists | `saved_views` (`state` jsonb) |
| **AI integrations** | Cookie classification of the unknown tail; draft page copy; alt-text suggestions | `ai_integrations` + `ai_usage_logs` |
| **Monitor** | Website analytics + consent opt-in rates as an owner console | New `platform.monitor.website` destination |
| **Notifications** | New submission, scan finding, domain verification failure | `notifications` table |

---

## 9. Security, tenancy and RLS rules

1. **Org-exact, never subtree, for consent and submissions.** The platform owner must not be able to read another tenant's consent ledger or web leads. `is_platform_owner()` grants access only to rows owned by the BespokeLMS org itself — the CRM's C2 rule, applied verbatim.
2. **Published site content is world-readable *by design*** — but only through the dedicated public reader, only for `state = 'published'`, only for the host-resolved org. Draft content is never readable publicly, and preview requires an authenticated, capability-holding user with a signed preview token.
3. **`tenant_domains` writes are the most privileged operation in the module**: platform owner + `platform.sudo` + audit. Verification before routing, always.
4. **Rate limiting and abuse:** per-IP and per-form throttles on submissions, per-host throttle on the consent write endpoint, and a hard cap on scan concurrency per tenant.
5. **Uploads:** MIME allowlist, size caps, no SVG from tenants without sanitisation (SVG is script), org-prefixed paths validated server-side.
6. **The consent endpoint is public and unauthenticated** — treat it as hostile input: strict schema validation, no free-text passthrough into the ledger, size caps on the purposes/vendors payload.

---

## 10. Phasing

Each phase is independently shippable and independently useful.

| Phase | Scope | Migrations | Notes |
|---|---|---|---|
| **0 — Menu moves** | Support Portal → Website & Consent; Live Chat → Communication ▸ Conversations; Communication sub-groups; Knowledge Base folded in | none | **Data only.** Draft → publish in the builder. Do this now |
| **1 — Surfaces & domains** | `tenant_domains`, `ResolveHost`, surface routing, theme-from-host; `app.bespokelms.com` cutover; `www` on a CMS-rendered holding page | 044 | Unblocks everything; also fixes the stale Netlify login redirect |
| **2 — CMS core** | Sites, pages, versions, blocks, block registry + `web:sync-blocks`, renderer, preview/publish/rollback, media, SEO, sitemap, redirects | 045–047 | Launch block set §5.2 |
| **3 — Components** | Site menus (nav builder extension + polymorphic targets); forms + CRM pipeline + autoresponders | 048–049 | `ALTER TYPE` migrations kept separate from first use |
| **4 — Consent (C1–C4)** | Sites/domains, banner designer, ledger, preference centre, **embeddable loader + blocking engine**, geo rulesets, multi-language, Consent Mode v2, GPC, CRM consent card | 050–053 | See the CMP build spec. Works on external sites too |
| **5 — Scanner (C5)** | Crawler worker, three scenarios, multi-locale, classification cache, auto-declaration, diff alerts | 054–055 | Needs container infrastructure; the moat |
| **6 — Support portal & live chat** | Portal surface, article rendering, ticket forms → support desk board; chat widget config + conversations inbox; Freshdesk cutover | 054–055 | `support.bespokelms.com` |
| **7 — Commercialisation (C6–C7)** | Provisioning API, webhooks, per-tenant consent host with auto-SSL, white-label toggles, packaging | 056 | Base + per-domain + flat white-label add-on |

**The BespokeLMS marketing site itself** lands across Phases 1–4: a holding page in Phase 1, the real site in Phase 2, forms in Phase 3, banner in Phase 4.

---

## 11. The first asset — www.bespokelms.com

Proposed sitemap, all data-bound where numbers appear:

```
/                       Hero · Value props · Course grid (live) · Logo strip · Testimonial · CTA
/platform               Feature sections · Screenshots · Accessibility & standards statement
/platform/white-label   The white-label story — the strongest differentiator you have
/platform/consent       The CMP as a product in its own right
/courses                Live catalogue from `courses` (published, territory-filtered)
/courses/{slug}         Course detail — outline, CPD points, accreditation, pricing
/who-its-for            Resellers · In-house · Own-brand — mapped to `operator_subtype`
/pricing                From `pricing_defaults` / `v_course_effective_pricing`
/about                  Teach HQ Limited, the company behind the platform
/contact                Contact form → CRM (lead)
/demo                   Book a demo → CRM (lead + deal on the default pipeline)
/legal/privacy          Under change control
/legal/cookies          Auto-generated declaration block
/legal/terms
/legal/accessibility    WCAG 2.2 AA statement — genuine, since the platform is built to it
/privacy/preferences    Consent preference centre
```

Menus: `site_primary` (Platform, Courses, Who it's for, Pricing, About), `site_utility` (Log in → `app.bespokelms.com`, Book a demo), `site_footer` (three columns + legal row). All built in the existing menu builder once §2.3's polymorphic target lands.

---

## 12. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| **D1** | Do site menus live in `nav_menus` with new types, or a separate `web_menus` table? | **`nav_menus` + `target_type`/`target_id`.** One engine, one publish path |
| **D2** | Blocks normalised (`web_blocks` rows) or a single `blocks jsonb` on the version? | **Normalised.** Queryable ("which pages embed this form?"), validatable, diffable |
| **D3** | Is the CMS available to all tenants, or platform-owner-only at first? | **Owner-only through Phase 4**, then enable per tenant via `tenant_modules`. Build it on ourselves first |
| **D4** | How does a course become publicly visible? New `is_public` on `courses`, or a `public` scope in `course_visibility`? | Lean `course_visibility` scope — it already models global/allowlist/private/denylist |
| **D5** | Does the marketing site share a session with the app (SSO from `www` to `app`)? | **No.** Separate cookie scope; "Log in" is a link. Revisit only if a self-serve signup flow needs it |
| **D6** | Scanner infrastructure: managed browser service or own Fargate pool? | Start managed (zero ops), move at ~£150–300/month of spend |
| **D7** | Consent-script domain per tenant (`consent.tenant.com`) — Phase 7 or earlier? | Phase 7. It's the commercial differentiator, not a launch requirement |
| **D8** | Do we keep Freshdesk for support and only build the portal *pages*, or replace it? | Portal pages first (Phase 6a), desk replacement only when the board engine's ticket flow is proven |
| **D9** | Blog / news: in scope for v1? | Pages with a `template = 'article'` + a "Latest posts" block covers it. No separate CMS object |
| **D10** | Consent record retention number | Processing duration + 6 years (UK limitation). Configurable per tenant, floor enforced |

---

## 13. Risks

- **Host routing is a single point of failure.** A bad `tenant_domains` row can serve the wrong tenant's brand. Mitigate with the unique constraint, verification-before-routing, 404-on-unknown, and a smoke test per host in CI.
- **The public surface bypasses the platform's authentication assumption.** The single dedicated reader plus a convention test is the control; a stray service-role query on a public route is the failure mode.
- **Scanner licence contamination.** Easy to pull in an NC-licensed tracker list without noticing. Record the licence decision per source in the repo.
- **Regulatory drift.** UK PECR reg 6 was rewritten on 5 February 2026 (new Schedule A1, two opt-out exceptions); ICO guidance was finalised on 29 April 2026; TCF moved to v2.3 on 1 March 2026. Treat any pre-2026 cookie material as stale, and re-verify before publishing tenant-facing compliance claims.
- **Deploy mechanics unchanged:** git pushes are performed by you, not from the sandbox; watch the `.git` lock-file workaround and the `_qa_scratch` + `mv -f` route for device commits.

---

## 14. Recommended next step

Phase 0 costs nothing and answers the question you actually asked: open the Navigation Menu Builder, drag `Support Portal` into **Website & Consent**, drag `Live Chat` into **Communication**, add the `Outbound` / `Conversations` sub-groups, and publish. The rail then reads the way the product is actually organised — content, surface, workload, channel — and Phase 1 has somewhere to land.
