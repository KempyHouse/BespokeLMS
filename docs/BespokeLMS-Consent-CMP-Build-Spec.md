# BespokeLMS Consent — Consent Management Platform: Build Specification

**Date:** 25 July 2026 · **Status:** Build spec for review — nothing applied
**Supersedes** §6 of `BespokeLMS-Website-Consent-Module-Proposal.md`, which sketched a consent engine scoped to CMS-hosted sites only.

**Decisions taken:**

1. **Build, not integrate.** No Cookiebot API, no Didomi, no reseller arrangement. The CMP is BespokeLMS code running on BespokeLMS infrastructure against the BespokeLMS Supabase project.
2. **Runs anywhere.** A one-line embeddable script that works on any website — a tenant's existing WordPress, Shopify, Webflow or bespoke site — **plus** server-side render-time blocking on sites we host in the CMS. Two blocking paths, one config, one ledger.
3. **Full parity, including geo rulesets and multi-language.**

That third decision is what turns this from a feature into a product: a tenant who will never buy the LMS can buy the consent platform, and a reseller can offer it to their own clients under their own brand.

---

## 1. Product shape

| | |
|---|---|
| **Working name** | BespokeLMS Consent (white-labelled per tenant; the name never appears on a tenant's banner) |
| **Sold** | Standalone, or bundled with the Website module |
| **Module keys** | `consent` (the CMP), `website_cms` (the site builder) — independently enablable via `tenant_modules` |
| **Unit of configuration** | A **site** (a domain group): one config, one banner, one declaration, N domains |
| **Unit of billing** | Base plan + per-domain increment + a flat white-label add-on tied to a custom consent domain |

**The four things that beat the incumbent**, and which must survive every scoping conversation:

1. **A provisioning API.** Cookiebot has none — onboarding is an invite email, one customer at a time. Ours creates a site, publishes a banner and attaches a domain from code, because tenants already exist as rows in `organizations`.
2. **Real RBAC.** Cookiebot has no team accounts at all; credential sharing is the documented workaround. We have Supabase RLS and `profile_capabilities` already.
3. **Per-tenant branding as a toggle**, not a CSS hack. Cookiebot publishes an article telling you to `display:none` its own logo.
4. **Host-based blocking rules instead of file-based.** Cookiebot gates whole JS bundles behind marketing consent — if `bundle.js` sets one marketing cookie, the entire application waits for consent. §4.4 fixes this properly.

---

## 2. System architecture

```
┌─ ADMIN (authenticated, inside the LMS) ──────────────────────────────┐
│  Website & Consent ▸ Consent                                         │
│  Sites · Domains · Banner designer · Purposes · Vendors · Cookies    │
│  Scans · Consent records · Reports · Install · Settings              │
└──────────────────────────────────────────────────────────────────────┘
              │ publish (versioned, hashed, screenshotted)
              ▼
┌─ CONFIG DISTRIBUTION ────────────────────────────────────────────────┐
│  consent.bespokelms.com/c/{site_key}/{version}.json   (immutable)    │
│  consent.bespokelms.com/c/{site_key}/current.json     (short TTL)    │
│  Public bucket + CDN. No database read on the hot path.              │
└──────────────────────────────────────────────────────────────────────┘
              │
      ┌───────┴────────────────────────────────┐
      ▼                                        ▼
┌─ EXTERNAL SITE ──────────────┐   ┌─ CMS-HOSTED SITE ─────────────────┐
│ <script src=".../consent.js" │   │ Server-side render-time gating.    │
│   data-site="…" async>       │   │ Blocked embeds never reach HTML.   │
│ Loader + blocking engine     │   │ Same runtime for UI + preferences. │
│ → UI bundle (lazy)           │   │ Blocking engine mostly idle.       │
└──────────────────────────────┘   └────────────────────────────────────┘
              │ POST /api/v1/consent  (CORS-restricted to verified domains)
              ▼
┌─ LEDGER + CRM ───────────────────────────────────────────────────────┐
│ consent_records (append-only) → crm_contacts.consent_id → timeline   │
│ → ConsentGate::allows() gates every outbound marketing send          │
└──────────────────────────────────────────────────────────────────────┘

┌─ SCANNER (container worker, out of band) ────────────────────────────┐
│ Playwright/CDP · multi-scenario · multi-locale · UK/EU vantage       │
│ → observed_* → classification → declaration → diff alerts            │
└──────────────────────────────────────────────────────────────────────┘
```

Three properties fall out of this shape and each is a deliberate improvement on the incumbent:

- **Nothing on the visitor hot path touches Postgres.** Config is a static, immutable, CDN-cached JSON document. Cookiebot does the same; the difference is we can publish per-tenant to a per-tenant domain.
- **The write path is the only public database endpoint**, so it gets all the hardening attention (§9).
- **The scanner never runs in the web tier.** Headless Chromium cannot run on Laravel Cloud or in a Supabase Edge Function; it is a separate worker with its own queue.

---

## 3. Configuration and delivery

### 3.1 The config document

Published on every banner publish. Immutable, content-addressed, versioned.

```jsonc
{
  "v": 1,
  "site": "bl_9f2a…",              // public site key, not a UUID from the DB
  "version": 14,
  "hash": "sha256:…",              // interface provenance; written into every consent record
  "published_at": "2026-07-25T09:12:00Z",
  "lifetime_days": 180,
  "reprompt_on_change": true,
  "blocking": {
    "mode": "auto",                // auto | manual | off (server-side sites use "off")
    "fail": "closed",              // closed | open  — §4.6
    "hosts": {                     // host → purpose. THE fix for bundle blocking (§4.4)
      "www.googletagmanager.com": "analytics",
      "connect.facebook.net": "marketing",
      "js.hs-scripts.com": "marketing",
      "snap.licdn.com": "marketing"
    },
    "selectors": [                 // explicit escape hatch for inline/first-party scripts
      { "match": "script[data-consent='marketing']", "purpose": "marketing" }
    ],
    "strip_hints": true            // remove preconnect/dns-prefetch to non-consented hosts
  },
  "purposes": [
    { "key": "necessary",     "required": true },
    { "key": "functional",    "required": false },
    { "key": "analytics",     "required": false, "opt_out_regions": ["GB"] },
    { "key": "marketing",     "required": false },
    { "key": "personalisation","required": false }
  ],
  "vendors": [
    { "id": "v_ga4", "name": "Google Analytics 4", "purpose": "analytics",
      "privacy_url": "https://policies.google.com/privacy", "hosts": ["www.google-analytics.com"] }
  ],
  "geo": {
    "default": "gdpr",
    "rules": [
      { "match": "GB",                 "ruleset": "uk_pecr" },
      { "match": "EEA",                "ruleset": "gdpr" },
      { "match": "CH",                 "ruleset": "gdpr" },
      { "match": "US-CA,US-CO,US-CT",  "ruleset": "us_optout" },
      { "match": "*",                  "ruleset": "none" }
    ]
  },
  "consent_mode": { "enabled": true, "url_passthrough": true, "ads_data_redaction": true },
  "gpc": { "honour": true, "applies_to": ["marketing", "personalisation"] },
  "ui": {
    "layout": "dialog",
    "position": "centre",
    "overlay": true,
    "tokens": { "surface": "--color-surface", "text": "--color-text",
                "accent": "--color-brand-primary", "radius": "--radius-lg" },
    "logo_url": "https://…/branding/…/logo.svg",
    "powered_by": false            // white-label toggle — a boolean, not a CSS hack
  },
  "i18n": {
    "default": "en-GB",
    "available": ["en-GB","cy","fr","de","es","it","nl","pt","pl","sv","da","nb","fi","cs","el","ro"],
    "strings_url": "…/i18n/{locale}.json"   // lazy-loaded, one small file per locale
  },
  "endpoints": { "consent": "https://consent.bespokelms.com/api/v1/consent" }
}
```

**Why the string bundles are separate:** parity requires ~16+ languages at launch and Cookiebot ships 46. Inlining them all would put ~100KB of dead weight on every page load. One locale file, lazily fetched only after the banner decides it needs to render, keeps the loader small.

### 3.2 Domains, keys and the custom consent domain

- `consent.bespokelms.com` is the platform default host for the script, config and write API.
- A tenant on the white-label add-on gets `consent.theirdomain.com` (CNAME → our ingress, automatic certificate). **This is the single most valuable commercial feature in the module** — Didomi does it per domain, consentmanager allows one per *account*, Sourcepoint's is account-branded, Piwik PRO is one per instance. Nobody does it per client the way this design does.
- The **site key** (`bl_…`) is public and appears in HTML. It is not a secret and grants nothing except reading a published config and writing a consent record from a verified origin.
- Every domain that may embed the script must be listed on the site and DNS-verified. The config endpoint and the write API both enforce origin against that list (§9.1).

### 3.3 Caching and invalidation

| Object | Cache | Invalidation |
|---|---|---|
| `{version}.json` | `immutable, max-age=31536000` | never — new version, new URL |
| `current.json` | `max-age=300, stale-while-revalidate=86400` | on publish |
| `consent.js` (loader) | `max-age=3600` + content hash in the filename | on release |
| `i18n/{locale}.json` | `immutable` per config version | with the config |

`current.json` carries only `{version, url, hash}` — a ~120-byte pointer. The loader fetches the pointer, then the immutable config. Five-minute worst-case staleness on a banner change, zero on a cache hit, and a publish is never a thundering herd against the database.

---

## 4. The client runtime

Two artefacts, deliberately split — this is where Cookiebot's architecture hurts most and where we do better.

| | Size budget (gzipped) | Loading | Job |
|---|---|---|---|
| **Loader + blocking engine** | **≤ 9 KB** | Synchronous, first in `<head>` (auto mode) | Patch the DOM/network surface, read the consent cookie, apply Consent Mode defaults, decide whether UI is needed |
| **UI bundle** | ≤ 28 KB | Async, only when a banner or preference centre must render | Banner, preference centre, declaration table, focus management, animations |

Cookiebot ships one script that must be synchronous, first in `<head>`, and carries the whole UI — which is why its own documentation offers "switch to manual blocking" as the remedy for render delay. Splitting means the *blocking* is synchronous (it must be) while the *UI* is not (it needn't be).

### 4.1 Boot sequence

```
1  Read the first-party consent cookie (name: __bl_consent, JSON, base64url)
2  If a valid, unexpired record exists whose config_hash matches → apply state, no UI
3  Install blocking patches BEFORE anything else can execute (auto mode)
4  Push Consent Mode defaults (denied unless the record says otherwise)
5  Fetch current.json → immutable config  (both CDN, both usually warm)
6  Resolve region (server-stamped, §5.1) and locale (§6.2)
7  If the ruleset requires a decision and none is stored → lazy-load the UI bundle + strings, render
8  On decision: write cookie → unblock granted hosts → update Consent Mode → POST the record
```

Steps 1–4 run before any network request. Step 5 is the only fetch on a returning visitor's page and it is a CDN hit.

### 4.2 Blocking — what actually gets patched

Everything below is required. Anything missing is a leak, and the leak is the product failing.

| Surface | Technique |
|---|---|
| `<script src>` in markup | Rewrite `type` → `text/plain`, move `src` → `data-bl-src`. Per MDN, a non-JS MIME type means the `src` attribute is ignored entirely — **no request is made** |
| Dynamically created scripts | Patch `document.createElement`, and intercept at `appendChild` / `insertBefore` / `replaceChild` / `insertAdjacentHTML` / `innerHTML` setter |
| `<img>` / `<iframe>` pixels | Leave `src` unset; hold in `data-bl-src`. Never set-then-remove |
| `fetch`, `XMLHttpRequest.open/send` | Wrap; reject or defer calls to non-consented hosts |
| `navigator.sendBeacon` | Wrap — the single most common analytics exfiltration path |
| `new Image().src`, `EventSource`, `WebSocket`, `Worker`, `SharedWorker` | Property/constructor patches |
| `navigator.serviceWorker.register` | Block, and **unregister on withdrawal** — service workers survive consent revocation otherwise |
| `<link rel=preconnect|dns-prefetch|prefetch|preload>` | **Strip when the host is not consented.** A `preconnect` to `google-analytics.com` reveals the visitor's IP to Google at TLS SNI time before any script runs. Almost no CMP handles this |
| CSS-loaded resources (`background-image`, `@font-face`) | Detected by the scanner and reported; blocked only when the tenant opts into the aggressive stylesheet rewrite |
| `document.cookie` setter | Optional strict mode: refuse writes matching a non-consented vendor pattern |
| MutationObserver | Backstop only. It is documented as asynchronous and purely observational — it **cannot** prevent a mutation, so it never counts as prior blocking. It exists to catch and neutralise what the patches missed, and to log it |

### 4.3 The unblocking gotcha, stated once so nobody re-learns it

Setting `el.type = 'text/javascript'` on a blocked script **does not execute it.** The HTML specification only "prepares" a script element on insertion, on `src` being set while connected, or on children changing — never on a `type` mutation. The unblocker must **clone every attribute onto a fresh `<script>` element and insert that**, preserving document order for non-async scripts. Getting this wrong produces a CMP that appears to work in testing and silently never fires anyone's analytics in production.

### 4.4 Host-based rules, not file-based — the Cookiebot bug we don't inherit

Cookiebot derives a per-domain checklist of "consent checksums, files, paths and keyword matchings" and blocks *files*. Its own documentation concedes the consequence: *"if you have a file bundle.js that requires consent for necessary, statistical, and marketing cookies, then this file will only be allowed to load if a visitor accepts statistical and marketing cookies."* On any bundler-based site that gates the entire application behind marketing consent.

Our rules key on **destination host** for network interception, plus **explicit attributes** for first-party code:

```html
<!-- Explicit, for a tenant's own bundled code -->
<script src="/app.js" data-consent="analytics"></script>

<!-- Or, inside the bundle, the correct pattern: -->
<script>
  window.BespokeConsent.on('analytics', () => initAnalytics());
</script>
```

A first-party bundle is never blocked as a file. The calls it makes to third-party hosts are intercepted individually, and the tenant's own code subscribes to purposes instead of being gated wholesale. This is documented as the recommended integration and it is genuinely better advice than the incumbent's.

### 4.5 Server-side blocking (CMS-hosted sites)

Where we render the page, the blocking engine is nearly redundant: a block whose `requires_purpose` is not granted never emits its embed. The renderer reads the consent cookie server-side and emits either the real embed or a token-styled placeholder with a "Load this content" affordance that grants the purpose on click and hydrates in place.

The advantage is structural rather than marginal: no `<head>` ordering constraint, no preload-scanner race, no bundle problem, no fail-open path, and no measurable effect on Core Web Vitals. **No vendor can offer this for arbitrary customer sites.** We can offer it for every site we host, and it should be the headline of the CMS/CMP bundle.

### 4.6 Fail-closed by default, and say so

If the config cannot be fetched, `mode: auto` keeps everything non-necessary blocked. Cookiebot's auto mode fails open — its documentation notes that manual mode "works even if the Cookiebot script fails to load," which is a concession. Fail-closed is the correct default for a compliance product; make it configurable per site, log every fail-closed page view, and alert the tenant if the rate crosses a threshold, because a fail-closed CMP with a CDN problem looks like a broken website.

### 4.7 Public JS API — parity, plus a Cookiebot migration shim

```js
BespokeConsent.consent            // {necessary, functional, analytics, marketing, personalisation}
BespokeConsent.vendors            // {v_ga4: true, v_hubspot: false, …}
BespokeConsent.hasResponse        // boolean
BespokeConsent.method             // 'accept_all' | 'reject_all' | 'save_preferences' | 'implied_optout'
BespokeConsent.regulation         // 'uk_pecr' | 'gdpr' | 'us_optout' | 'none'
BespokeConsent.consentId          // pseudonymous id
BespokeConsent.show() / .hide() / .renew() / .withdraw()
BespokeConsent.submitCustomConsent({analytics: true, marketing: false})
BespokeConsent.on('analytics', cb)          // fires immediately if already granted
BespokeConsent.off(purpose, cb)
BespokeConsent.runScripts()                 // manual unblock trigger
```

Events on `window`: `blConsentLoad`, `blConsentReady`, `blConsentAccept`, `blConsentDecline`, `blConsentChange`, `blConsentDialogDisplay`, `blConsentTagsExecuted`. Also pushed to `dataLayer` for GTM triggers.

**Migration shim (opt-in, `data-compat="cookiebot"`).** Aliases `window.Cookiebot.consent.{necessary,preferences,statistics,marketing}`, `.hasResponse`, `.renew()`, `.withdraw()`, and re-emits `CookiebotOnAccept` / `OnDecline` / `OnLoad` / `OnConsentReady` / `OnTagsExecuted`; maps `data-cookieconsent="statistics"` attributes to our purposes. A tenant switching from Cookiebot changes one script tag and nothing else. **This is a sales weapon and it costs about a day of work** — build it in Phase C3, not "later".

### 4.8 Performance budget (enforced in CI, not aspired to)

| Metric | Budget |
|---|---|
| Loader transfer | ≤ 9 KB gzipped |
| Loader main-thread time | ≤ 20 ms on a mid-tier mobile CPU |
| UI bundle | ≤ 28 KB gzipped, loaded only when rendering |
| Locale strings | ≤ 4 KB per locale |
| CLS contributed by the banner | **0** — fixed positioning, no reflow of page content |
| Requests before consent (auto mode, marketing declined) | **0 to any non-consented host**, asserted by the CDP test suite (§11.2) |

---

## 5. Geo rulesets

### 5.1 Region resolution — server-side, never in the browser

The config-pointer and consent endpoints are behind a CDN that stamps the request country/region (Cloudflare `CF-IPCountry` and `CF-Region`, or the equivalent Laravel Cloud edge header — **confirm which is available before Phase C2; if neither, a MaxMind lookup at our edge is the fallback**). The region is returned as a short-lived, non-identifying stamp:

```
GET /c/{site_key}/current.json  →  { "version": 14, "url": "…", "region": "GB", "ruleset": "uk_pecr" }
```

No GeoIP database ships to the client, no third-party geo API is called from the visitor's browser (which would itself be a tracker firing before consent — an error several CMPs actually make), and the IP is never persisted.

### 5.2 The rulesets

| Ruleset | Applies | Behaviour |
|---|---|---|
| `uk_pecr` | GB | Opt-in for marketing/functional/personalisation. **Analytics and appearance are opt-out** under the Schedule A1 exceptions inserted when PECR reg 6 was rewritten on 5 February 2026 — but the banner still discloses them and offers a decline. Reject-all parity. 6-month lifetime |
| `gdpr` | EEA + CH | Opt-in for everything non-necessary. Reject-all parity on layer one. No pre-ticked toggles. No legitimate-interest tab for advertising. 6-month lifetime |
| `us_optout` | CA, CO, CT, VA, UT and the rest of the 20-state cluster | Prior blocking off by default; a **"Do Not Sell or Share My Personal Information"** link, a preference centre, and **Global Privacy Control honoured as a valid opt-out signal** — which is mandatory in several of these states, not optional |
| `none` | Everywhere else | No banner by default; the preference centre remains reachable. Tenant-overridable to `gdpr` for a single global posture |

Rulesets are **platform-owned rows**, not tenant-editable code — tenants choose a mapping, not a legal interpretation. A tenant may override which ruleset a region maps to (some choose `gdpr` worldwide for simplicity) and may not invent one.

⚠️ **The UK opt-out nuance is the one most likely to be got wrong.** It is new (February 2026), it is narrow, and applying it to marketing cookies would be a straightforward breach. Encode it as a per-purpose `opt_out_regions` list validated against the ruleset, not as a free-text setting.

### 5.3 Banner variants per region

One config, N rendered variants — not N configs. Cookiebot requires a separate domain group (and therefore a separate CBID and separate configuration object) per region, which is why multi-region Cookiebot deployments sprawl. Ours resolves the ruleset at render time from one document, so a tenant maintains one banner and one declaration.

---

## 6. Multi-language

### 6.1 What gets translated

| Layer | Source | Translation route |
|---|---|---|
| Banner chrome (buttons, headings, standard body copy) | Platform-seeded template strings | Professionally translated once, shipped with the platform, versioned |
| Tenant custom copy | `consent_banner_configs.copy` jsonb per locale | Manual, **or AI-assisted via the existing `ai_integrations` layer** with a human review step |
| Purpose names and descriptions | `consent_purposes` (+ tenant-scoped rows) | Same route |
| Vendor descriptions | `consent_vendors` | Same route |
| Cookie declaration purposes | `cookie_classifications` | Platform-maintained, translated centrally — the tenant never translates these |

**Cookiebot does not document auto-translation of custom banner copy** — its "46 languages" covers template strings only, so a tenant who writes their own body text ships it in one language. We already have an AI integration layer and `content_translations`; making custom copy translatable is a genuine, demonstrable gap-filler.

### 6.2 Locale resolution

`?bl_lang=` (explicit) → `<html lang>` → path/subdomain convention (`/de/`, `de.example.com`) → `Accept-Language` → site default. Resolved in the loader before the UI bundle is requested, so exactly one locale file is fetched.

### 6.3 Launch set

`en-GB` plus `cy, ga, fr, de, es, it, nl, pt, pl, sv, da, nb, fi, cs, sk, hu, ro, bg, el, hr, sl, et, lv, lt, mt` — the EU/EEA official set plus Welsh and Irish, which matter for UK public-sector and education buyers and which most competitors omit. Storage is `consent_i18n_strings (locale, key, value, source, reviewed_by)`, exported to the per-locale JSON on publish.

RTL is not needed for the launch set; the layout must not assume LTR anyway (logical CSS properties only, which the design tokens already encourage).

---

## 7. Data model

Migration family **050–056**. Numbering is provisional — a parallel session applied 039–043 today; run `list_migrations` before writing.

```sql
-- 050: sites, domains, purposes, vendors -----------------------------------
create type consent_category as enum ('necessary','functional','analytics','marketing','personalisation');
create type consent_ruleset  as enum ('uk_pecr','gdpr','us_optout','none');
create type consent_action   as enum ('accept_all','reject_all','save_preferences','withdraw','renew','implied_optout');
create type consent_method   as enum ('banner','preference_centre','api','form','in_app','gpc','placeholder_click');
create type scan_state       as enum ('queued','running','complete','failed','cancelled');
create type scan_scenario    as enum ('no_interaction','reject_all','accept_all');

create table consent_sites (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  web_site_id uuid references web_sites(id) on delete set null,  -- null = external site
  site_key text not null unique,                 -- public 'bl_…' key
  name text not null,
  default_ruleset consent_ruleset not null default 'gdpr',
  default_locale text not null default 'en-GB',
  lifetime_days integer not null default 180,
  reprompt_on_change boolean not null default true,
  blocking_mode text not null default 'auto',    -- auto|manual|off
  blocking_fail text not null default 'closed',  -- closed|open
  consent_mode_enabled boolean not null default true,
  honour_gpc boolean not null default true,
  powered_by boolean not null default true,      -- white-label toggle
  custom_script_host text,                       -- 'consent.tenant.com'
  status text not null default 'draft',          -- draft|live|suspended
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table consent_site_domains (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references consent_sites(id) on delete cascade,
  organization_id uuid not null,
  hostname text not null,
  include_subdomains boolean not null default false,
  verification_token text not null,
  verified_at timestamptz,
  last_seen_at timestamptz,                      -- last request observed from this origin
  created_at timestamptz not null default now()
);
create unique index on consent_site_domains (lower(hostname));

create table consent_purposes (
  key text not null,
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform default
  name text not null,
  description text not null,
  category consent_category not null,
  is_required boolean not null default false,
  opt_out_regions text[] not null default '{}',  -- e.g. {GB} for analytics under PECR Sch A1
  sort_order integer not null default 0,
  primary key (key, coalesce(organization_id, '00000000-0000-0000-0000-000000000000'::uuid))
);

create table consent_vendors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  site_id uuid references consent_sites(id) on delete cascade,
  name text not null,
  purpose_key text not null,
  privacy_url text,
  description text,
  hosts text[] not null default '{}',            -- drives host-based blocking
  cookie_patterns text[] not null default '{}',
  is_third_party boolean not null default true,
  status text not null default 'active'
);

-- 051: banner configuration, versioned + hashed ----------------------------
create table consent_banner_configs (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references consent_sites(id) on delete cascade,
  organization_id uuid not null,
  version_no integer not null,
  state version_status not null default 'draft',
  layout text not null default 'dialog',
  position text not null default 'centre',
  show_overlay boolean not null default true,
  style jsonb not null default '{}',             -- TOKEN KEYS ONLY, validated on save
  copy jsonb not null default '{}',              -- {locale: {title, body, accept, reject, …}}
  purposes text[] not null,
  geo_rules jsonb not null default '{}',
  config_json jsonb,                             -- the exact published document
  config_hash text,                              -- sha256 of config_json
  screenshot_path text,                          -- rendered proof per version+locale
  published_by uuid references profiles(id),
  published_at timestamptz,
  created_at timestamptz not null default now(),
  unique (site_id, version_no)
);

create table consent_i18n_strings (
  locale text not null, key text not null,
  organization_id uuid,                          -- null = platform template string
  value text not null,
  source text not null default 'platform',       -- platform|tenant|ai|professional
  reviewed_by uuid references profiles(id), reviewed_at timestamptz,
  primary key (locale, key, coalesce(organization_id,'00000000-0000-0000-0000-000000000000'::uuid))
);

-- 052: the ledger ----------------------------------------------------------
create table consent_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  site_id uuid not null references consent_sites(id) on delete cascade,
  consent_id uuid not null,                      -- pseudonymous visitor anchor
  domain text not null,
  occurred_at timestamptz not null default now(),
  action consent_action not null,
  method consent_method not null,
  purposes jsonb not null,                       -- {"analytics":true,"marketing":false,…}
  vendors jsonb,
  banner_config_id uuid references consent_banner_configs(id) on delete set null,
  banner_config_hash text not null,              -- survives config deletion
  policy_version text,
  ruleset consent_ruleset not null,
  locale text not null,
  country text,                                  -- derived at collection; IP discarded
  page_path text,                                -- path only, query string stripped
  user_agent_family text,
  expires_at timestamptz not null,
  crm_contact_id uuid references crm_contacts(id) on delete set null,
  profile_id uuid references profiles(id) on delete set null,
  superseded_by uuid references consent_records(id)
) partition by range (occurred_at);              -- monthly partitions
-- append-only: RLS grants INSERT + SELECT only. Withdrawal is a NEW row.

create index on consent_records (organization_id, consent_id, occurred_at desc);
create index on consent_records (site_id, occurred_at desc);

-- 053: scanner -------------------------------------------------------------
create table cookie_scans (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references consent_sites(id) on delete cascade,
  organization_id uuid not null,
  root_url text not null,
  scenarios scan_scenario[] not null default '{no_interaction,reject_all,accept_all}',
  locales text[] not null default '{en-GB}',
  vantage text not null default 'gb',
  max_pages integer not null default 200,
  state scan_state not null default 'queued',
  queued_at timestamptz not null default now(),
  started_at timestamptz, finished_at timestamptz,
  pages_scanned integer not null default 0,
  findings_count integer not null default 0,
  error text
);
create table scan_pages       (id, scan_id, url, status_code, load_ms, screenshot_path, scenario);
create table observed_cookies (id, scan_id, page_id, scenario, name, domain, path, expires_days,
                               http_only, secure, same_site, party, setter_request_id, setter_stack jsonb);
create table observed_storage (id, scan_id, page_id, scenario, kind, key, size_bytes);
create table observed_requests(id, scan_id, page_id, scenario, url_host, url_path,
                               resource_type, initiator jsonb) partition by range (created_at);
create table scan_findings    (id, scan_id, organization_id, code, severity, subject,
                               evidence jsonb, first_seen_scan_id, resolved_at);

-- GLOBAL — the only table in the module with no organization_id. This is the moat.
create table cookie_classifications (
  id uuid primary key default gen_random_uuid(),
  name_pattern text not null,
  domain_pattern text,
  vendor text, category consent_category, purpose_text text, retention_text text,
  confidence numeric(3,2) not null default 0.5,
  source text not null,                          -- ocd|badger|easyprivacy|cookieblock|llm|manual
  evidence jsonb,
  reviewed_by uuid references profiles(id),
  updated_at timestamptz not null default now()
);
create table tenant_cookie_overrides (organization_id, site_id, name_pattern, domain_pattern,
                                      category, purpose_text, retention_text, note, updated_by);

-- 054: declaration (the published cookie table) ----------------------------
create table consent_declarations (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references consent_sites(id) on delete cascade,
  organization_id uuid not null,
  version_no integer not null,
  generated_from_scan_id uuid references cookie_scans(id),
  entries jsonb not null,                        -- resolved: name, provider, purpose, expiry, type
  published_at timestamptz,
  unique (site_id, version_no)
);
```

**RLS.** Every table except `cookie_classifications` is **org-exact** — `owning organization = auth_org_id()`, and `is_platform_owner()` grants access only to rows owned by the BespokeLMS org itself. The platform owner must not be able to read a tenant's consent ledger; we are that tenant's **processor**, and the DPA must say so. `cookie_classifications` is readable by all authenticated users and writable only by the platform.

---

## 8. Admin surface

Under **Website & Consent ▸ Consent**. Every screen uses the existing `<x-data-table>`, `<x-ds-select>`, `<x-pill-switch>` components and design tokens.

| Screen | Contents |
|---|---|
| **Overview** | Opt-in rate (7/30/90 days), by purpose, by region; banner impressions; open findings; last scan; fail-closed rate |
| **Sites** | Create/duplicate a site; site key; blocking mode; ruleset; lifetime; white-label toggle |
| **Domains** | Add domain, DNS verification status, last-seen traffic, custom consent host + certificate status |
| **Install** | Copy-paste snippet, GTM template download, WordPress/Shopify instructions, **live verification** ("we can see your script on 3 of 4 domains"), Cookiebot-compat toggle |
| **Banner designer** | Live preview across layouts, locales and rulesets side by side; token pickers only; the regulator checklist enforced inline (reject-all parity cannot be switched off); publish captures hash + screenshot per locale |
| **Purposes** | Platform defaults plus tenant additions; category; opt-out regions; per-locale name/description |
| **Vendors** | Named third parties, hosts, privacy URLs, purpose mapping; auto-suggested from scan findings |
| **Cookies** | The declaration: every observed cookie, its classification, source and confidence; tenant override; "unclassified" queue |
| **Scans** | History, schedule (daily/weekly/monthly), scenarios, locales, run-now, per-scan report, **diff against previous** |
| **Consent records** | Search by `consent_id`, date, action, domain, purpose; export CSV/JSON; single-record proof view showing the exact banner version and screenshot that was displayed |
| **Reports** | Opt-in trends, per-purpose and per-vendor rates, region breakdown, banner A/B comparison |
| **Settings** | Lifetime, re-prompt policy, GPC, Consent Mode, fail mode, retention, DPA and ROPA notes |

**Preference centre and declaration are also embeddable** on any page, ours or the tenant's:

```html
<div data-bl-declaration></div>       <!-- auto-updating cookie table -->
<div data-bl-preferences></div>       <!-- inline preference centre -->
<a href="#" data-bl-open>Cookie settings</a>
<span data-bl-status></span>          <!-- current state + withdraw control -->
```

---

## 9. Public API, security and abuse

### 9.1 Endpoints

| Endpoint | Auth | Notes |
|---|---|---|
| `GET /c/{site_key}/current.json` | none | CDN, CORS `*`, tiny pointer |
| `GET /c/{site_key}/{version}.json` | none | CDN, immutable |
| `GET /c/{site_key}/i18n/{locale}.json` | none | CDN, immutable |
| `POST /api/v1/consent` | none | **Origin must match a verified domain on that site.** Rate-limited per IP and per `consent_id`. Strict schema; unknown keys rejected; ≤4 KB body |
| `GET /api/v1/consent/{consent_id}` | tenant API key | The visitor's own history, for a tenant's DSAR workflow |
| `POST /api/v1/sites` · `/domains` · `/banner/publish` | tenant API key + capability | **The provisioning API Cookiebot doesn't have** |
| `GET /api/v1/stats` | tenant API key | Opt-in rates, no personal data |
| Webhooks: `consent.recorded`, `scan.completed`, `cookie.discovered`, `finding.opened` | HMAC-signed | **Nobody in this market ships webhooks.** It is how a tenant wires consent into their own stack |

API keys are per organisation, hashed at rest, rotatable, scoped by capability, and never appear in a URL path — a direct correction of Cookiebot's static-key-in-the-URL design.

### 9.2 Threats and controls

| Threat | Control |
|---|---|
| Forged consent records ("we have proof they accepted") | Origin allowlist, rate limits, server-stamped timestamp and region, config hash validated against a published version, per-`consent_id` write ceiling |
| Site-key abuse from an unlisted domain | 403 + a "seen on an unverified domain" finding surfaced to the tenant (also a useful shadow-IT detector) |
| Ledger tampering | Append-only RLS; no UPDATE/DELETE grant; monthly partitions; superseding rows rather than edits |
| Config poisoning | Publishing requires `platform.sudo`-equivalent step-up + audit; the config is content-addressed |
| Domain hijack via an unverified custom host | Never route or serve an unverified host — the standard subdomain-takeover vector |
| PII creep into the ledger | Schema-level: no IP column, no full URL column, no free-text field. The database makes over-collection impossible rather than discouraged |
| DDoS on the write path | CDN rate limiting, bot scoring, and a client-side coalescing rule (one write per decision, not per page view) |

---

## 10. Compliance behaviour the engine enforces

Not guidance — behaviour that cannot be configured away.

1. **Reject-all on the first layer**, same layer, same click count, same visual weight as Accept.
2. **No pre-ticked toggles** anywhere, including the second layer.
3. **Granular per purpose**; no bundling; no legitimate-interest tab for advertising trackers.
4. **Named third parties** with per-vendor control.
5. **Withdrawal as easy as consent**, always reachable, and withdrawal *works*: stop the technologies, expire the cookies, unregister service workers, notify named third parties where an API exists, and treat withdrawal as a deletion request for data held under that consent.
6. **Nothing non-necessary fires before a decision** in opt-in regions — asserted by the test suite, not assumed.
7. **6-month lifetime, symmetric for accept and reject**, immediate re-prompt when the config hash changes. Stricter than the 90-day and 12-month competitor defaults, and aligned with both CNIL's consolidated recommendation and the ICO's April 2026 position.
8. **Consent Mode v2 sits behind prior blocking**, never instead of it. Advanced mode alone, with `gtag.js` fetched and pinging before any decision, is in our assessment not compliant with PECR reg 6 / Art. 5(3) — and tenants should be told plainly that combining advanced mode with real prior blocking removes most of the modelling benefit that motivates advanced mode. That trade-off is theirs to make knowingly.
9. **GPC honoured** as an opt-out where the ruleset recognises it.
10. **WCAG 2.2 AA on the banner itself**: `role="dialog"`, `aria-modal`, focus trap and restoration, Escape closes to the least-permissive state (never "accept"), full keyboard operation, 44px targets, contrast from tokens, screen-reader announcement, respects `prefers-reduced-motion`. The banner is the first thing every visitor meets and the most-audited component in the product.

**Proof retention** runs on its own clock: processing duration plus the limitation period — 6 years in the UK — configurable per tenant with a floor, not the 12 months Cookiebot erases at. Interface provenance (config JSON, hash, screenshot per locale) is retained indefinitely and contains no personal data, so it costs nothing to keep and answers the allegation that actually gets made — that the interface was manipulative.

---

## 11. Scanner

### 11.1 Pipeline

**Discover** (sitemap.xml → crawl `<a href>` within the registrable domain → tenant-supplied URL list for SPAs) → **load** (Playwright over CDP, one context per scenario, scroll to bottom, dwell 3–5s, `networkidle2` or a 15s ceiling) → **extract** (full cookie jar including HttpOnly and third-party via CDP `Network.getAllCookies`, localStorage, sessionStorage, IndexedDB names, all requests with initiator chains, canvas/font fingerprinting probes) → **classify** → **reconcile** against the published declaration → **findings**.

**Three scenarios per page** — no interaction, reject-all, accept-all — because that is the only way to detect the violations that matter, and they are the ones a tenant pays to be told about:

| Finding | Prevalence in the literature |
|---|---|
| Undeclared cookies | 82.5% of sites |
| Non-necessary cookies set before any interaction | 69.7% |
| **Cookies set despite rejection** | **21.3%** |
| Unclassified cookies in the declaration | 25.4% |
| Declared expiry wrong vs observed | 9.1% |

94.7% of sites have at least one violation, and only 53.6% of observed cookies match any declaration — so a scanner that merely reconciles against the declared table under-reports by roughly half.

### 11.2 Classification

Four layers, in order: **tenant override** (always wins) → **exact/pattern match** in `cookie_classifications` → **vendor host inference** from the request initiator → **LLM classification of the tail** via the existing `ai_integrations` layer, written back to the global cache with a confidence score and evidence. Anything below a confidence threshold lands in the tenant's "unclassified" queue rather than being silently guessed — Cookiebot's fail-open behaviour here (unclassified cookies are *not* blocked) is a defect we should not copy.

**Bootstrap corpus, permissive licences only:** Open Cookie Database (Apache-2.0, ~2,264 cookies, ships an EDPB-format export), badger-sett (MIT, daily), Brave adblock-lists (MPL-2.0), EasyPrivacy (CC BY-SA branch), and the CookieBlock Zenodo corpus (CC-BY-4.0, 304k labelled cookies from 29,398 sites — commercial retraining permitted with attribution).

⚠️ **Excluded, permanently, and recorded in the repo:** DuckDuckGo Tracker Radar, Disconnect, Ghostery trackerdb (all CC BY-**NC**-SA), cookiedatabase.org (CC BY-NC-**ND**, and API-gated since 1 June 2026), Cookiepedia (OneTrust proprietary, `robots.txt` 403s non-browser clients). Getting this wrong is a due-diligence problem later, not a technical one.

### 11.3 Infrastructure

Managed browser service first (Cloudflare Browser Rendering or Browserbase — zero ops), moving to a self-hosted Playwright pool on Fargate/EC2 Spot at roughly £0.11 per 1,000 page-loads once spend passes ~£150–300/month. ⚠️ **Not** the HTML-rendering scraper APIs (ScraperAPI, ScrapingBee, Zyte HTTP tier) — a real CDP session is required for the full cookie jar, initiator chains and re-runnable consent states. ⚠️ **Browserless is SSPL-licensed** and unusable in a closed-source commercial product; Steel Browser (Apache-2.0) is the licence-clean self-host option.

Bot protection is solved by **allowlisting**, not an arms race: documented static egress IPs plus an `X-BL-Scanner` token that tenants allowlist at onboarding. Scan from a **UK/EU vantage point** or the crawler captures the US banner variant and reports nonsense. Jobs are idempotent, resumable, jittered within their window, and hard-timeout at 30s per page and 30 minutes per scan. Raw HAR evidence goes to Storage with a 90-day lifecycle, never into Postgres.

**Diff against the previous scan and alert on new cookies.** "Your marketing team added Hotjar last Tuesday and it is firing before consent" is the email that renews the subscription.

---

## 12. Testing

| Layer | Approach |
|---|---|
| **Blocking correctness** | Playwright + CDP fixture suite: a corpus of pages embedding GA4, GTM, Meta Pixel, LinkedIn, HubSpot, YouTube, Maps, Hotjar, Intercom, bundled first-party code, `document.write`, dynamic injection, and resource hints. **Assert zero requests to non-consented hosts** via the network log, not by inspecting the DOM |
| **Unblocking correctness** | Assert each blocked script actually executes after consent — the clone-and-reinsert trap (§4.3) is silent otherwise |
| **Fail modes** | Config 404 / 500 / timeout → fail-closed holds; manual mode still functions |
| **Regulator checklist** | Automated assertions per ruleset: reject-all present on layer one, equal size and prominence, no pre-ticked toggles, granular per purpose |
| **Accessibility** | axe-core on every layout × locale × ruleset; manual keyboard and screen-reader passes on the banner; Escape resolves to the least-permissive state |
| **Performance** | Bundle-size gates in CI; Lighthouse budget on a reference page; CLS asserted at 0 |
| **Ledger integrity** | Attempted UPDATE/DELETE must fail under RLS; withdrawal creates a new row; cross-tenant read attempts must return nothing |
| **Geo** | Synthetic requests with forged edge headers across GB / DE / US-CA / AU, asserting ruleset selection and banner variant |
| **Cross-browser** | Chrome, Firefox, Safari (including ITP cookie lifetime), Edge, iOS Safari, Android Chrome |
| **Migration shim** | A real Cookiebot integration snippet must work unmodified against our script with `data-compat="cookiebot"` |

---

## 13. Phases

| Phase | Scope | Migrations |
|---|---|---|
| **C1 — Foundations** | `consent_sites`, domains + verification, purposes, vendors; admin CRUD; site key issuance; config publish pipeline (JSON + hash + CDN) | 050 |
| **C2 — Banner & ledger** | Banner designer (tokens, live preview, checklist enforced), i18n storage, publish with screenshot capture; loader + UI bundle; write API; `consent_records` partitioned; preference centre; declaration embed; **geo rulesets**; Consent Mode v2; GPC | 051–052 |
| **C3 — Blocking engine** | Full patch surface (§4.2), host-based rules, hint stripping, fail-closed, server-side render gating for CMS sites, GTM template, **Cookiebot compat shim**, CDP test suite | — |
| **C4 — CRM & comms wiring** | `crm_contacts.consent_id`, consent card on the contact, timeline activities, `ConsentGate::allows()` gating every outbound marketing send, form-captured consent | 053 |
| **C5 — Scanner** | Worker, three scenarios, multi-locale, classification cache + bootstrap corpora, findings, declaration generation, scheduling, diff alerts | 054–055 |
| **C6 — API & reporting** | Provisioning API, stats API, webhooks, CSV/JSON export, reports, A/B comparison | 056 |
| **C7 — Commercialisation** | Per-tenant consent host with automatic certificates, white-label toggles across banner/emails/dashboard, packaging and reseller terms | — |

C1–C3 is a sellable product on their own: a compliant, branded, blocking, multi-region, multi-language banner with an evidential ledger. C5 is what makes it worth a subscription rather than a one-off setup.

---

## 14. Open decisions

| # | Decision | Recommendation |
|---|---|---|
| **E1** | Which edge provides the geo header — Cloudflare in front of Laravel Cloud, or Laravel Cloud's own? | Confirm before C2. If neither, MaxMind at our edge; **never** a client-side geo API |
| **E2** | Consent cookie: first-party set by JS (works everywhere, ITP-capped at 7 days on Safari) or via a CNAMEd first-party endpoint (survives ITP, needs the custom host) | JS cookie for the base tier; the CNAMEd path is a white-label add-on benefit. **Document the Safari 7-day cap honestly** — it means re-prompting, and every competitor is quiet about it |
| **E3** | Do we offer cross-domain consent sharing? | **No, and say why.** Cookiebot's is documented as working only within one top-level domain, requires third-party cookies, DNT off and Preferences consent, and fails silently for exactly the privacy-conscious users it matters for. Support a domain group under one registrable domain and be straight about the limit |
| **E4** | Is the ledger write synchronous with the banner decision, or queued? | Fire-and-forget with a retry queue in the client; the cookie is the source of truth for behaviour, the ledger is the evidence |
| **E5** | Do tenants get the raw scan HAR? | Summary and findings in the UI; HAR on request, 90-day lifecycle. It is large and contains their visitors' request data |
| **E6** | Free tier? | A single-domain free tier is Cookiebot's main acquisition channel and costs us little (scanning is ~£0.02–0.06 per 50-page site). Recommend one, capped at 50 pages and monthly scans |
| **E7** | Who owns the compliance claim? | We supply a tool; the tenant is the controller. Ship a "compliance posture" report, never a compliance certificate, and put that in the DPA |

---

## 15. What this replaces

For BespokeLMS itself, this module removes the need for Cookiebot or any equivalent on every property we run. For tenants it becomes a product line that can be sold with or without the LMS. And it closes the loop that no third-party CMP can close: **a visitor's cookie choice, made on a marketing page, is on their CRM contact record within seconds, and it is what decides whether the next marketing email is allowed to send.**
