# BespokeLMS — Tech-stack & architecture decision

**Which option meets the requirements · 22 July 2026**
*Answers "what's the best option for the tech stack?" against the full requirement set: multi-tenant white-label SaaS, PHP/Laravel + Supabase + Flutter, recognised coding standards, WCAG 2.2 AA, mobile-first, tokens-only design system, and no mock data. No code has been changed; this is a decision for sign-off before implementation.*

---

## The short answer

**Build the real stack properly — Laravel + Supabase + Flutter — and treat the current dashboard as a visual/structural reference only, exactly as it is labelled ("Mock-up only").** Do **not** evolve the single-file prototype into the product.

This **revises the "wire the prototype now" option I offered last turn.** That was the right call for a quick demo; it is the wrong call against these requirements. The prototype cannot satisfy tokens-only styling, PSR-12/Laravel standards, Eloquent-first data access, automated enforcement, or "no mock data" — the evidence is below.

Crucially, this is a **re-platform, not a redesign.** You are happy with the UI and it must not change. So the approved design is *frozen* and becomes the **source of the design tokens** — we harvest its exact colours, spacing, type, radii and shadows into the design system, rebuild the same screens token-driven, and prove pixel-parity with screenshot diffs. Same look; production foundation underneath.

---

## What I reviewed (full review, as requested)

**Database (Supabase `pqmdtqsscyltykgcwwus`, eu-west-1, live).** 17 tables, RLS on every one, snake_case naming, `timestamptz` (ISO 8601), cascading org-tree tenancy, 5-tier RBAC, compliance views. **This is already standards-aligned and is kept.** Seeded: 8 orgs, the 4 operator tenants each with a login-ready admin, Marcus Reed (owner), plus client/team/learner demo accounts.

**Codebase (`teachhq-dashboard-tailwind.html`, 336 KB).** Single file, Tailwind **Play CDN** (runtime, not a compiled build), vanilla JS, 100% inline mock arrays, saved views in `localStorage`, **no Supabase code, no auth, no build step, no linting**. Identity today is a cosmetic label swap.

**Token compliance — the decisive finding.** The file contains **114 raw 6-digit hex colours** and **573 arbitrary bracketed utility values** (e.g. `min-h-[158px]`, `text-[10px]`, `bg-[#cde2d6]`). It *does* define a good `@theme` token seed (the `teachhq`/`slatecard`/`paper` palette, RAG colours, shadow scale) — but that seed coexists with hundreds of one-off values. Against "no hard-coded visual values; tokens only," the prototype is the opposite of compliant. That is not a defect to patch in place — it is why the design must be re-expressed as tokens on a real build.

**Repository (`KempyHouse/BespokeLMS`, = local `C:\Claude\BespokeLMS`).** Greenfield for the app: HTML mock-ups + `/docs` + `.git` + `.netlify`. **No Laravel, no `composer.json`, no `package.json`.** Nothing to refactor — the Laravel app is a clean start.

**Hosting / links.** Netlify (`bespokelms-app`) is a **static** host — it cannot run Laravel; it stays as the marketing/reference site and rollback. `bespokelms.com` (Namecheap) is the tenancy root for operator subdomains. Resend is the email provider (see §5).

---

## Why not just extend the prototype?

| Requirement | Extend the prototype (Option A) | Build the stack (Option B) |
|---|---|---|
| Tokens only, no hard-coded values | ✗ 114 hex + 573 arbitrary values baked in | ✓ tokens harvested from the design, then enforced |
| PHP PSR-12 / PER 3.0, Laravel best practice, Pint | ✗ no PHP at all | ✓ Laravel from day one |
| Eloquent-first, thin controllers, Form Requests | ✗ browser-only, no server layer | ✓ core pattern |
| No mock data; real DB-driven + proper states | ✗ built entirely on mock arrays | ✓ Supabase-driven, loading/empty/zero states |
| Automated lint/format/standards enforcement | ✗ none possible on a CDN single file | ✓ Pint, PHPStan, Prettier, sqlfluff, CI gates |
| Strict multi-tenant isolation, white-label | ✗ single hard-coded tenant | ✓ org-tree tenancy + RLS + per-tenant tokens |
| Flutter sharing one backend | ✗ nothing to share | ✓ shared Supabase + API |
| Keep the approved look | ✓ (it *is* the look) | ✓ reproduced to pixel-parity from the same tokens |

Option A wins only on the one thing we are protecting anyway — the look — and Option B protects that too, by construction.

---

## Recommended architecture

A layered, tenant-aware design on the stack you named:

**Identity — Supabase Auth (recommended IdP).** Already seeded with your accounts, RLS is built around `auth.uid()`, and Flutter can share it. JWT carries role + org. Laravel verifies the Supabase JWT in middleware and loads the `profiles` row. **Email (set/reset passwords, invites) is sent via Resend** — see §5.

**Application — Laravel** (Blade + Vite + compiled Tailwind). Thin controllers, Form Request validation, Eloquent-first, RESTful routes, Pint + PHPStan/Larastan. Renders only the workspaces/menus a role and tenant allow (forbidden nav not emitted, not just hidden).

**Data & tenancy — Supabase Postgres via Eloquent.** Single shared database, **org-tree multi-tenancy** (already modelled). Tenant isolation is enforced **twice**: a Laravel global `TenantScope` keyed to the caller's org subtree (primary, app-layer), and Postgres **RLS as defence-in-depth** (and the enforcement layer for any direct Supabase-SDK/Flutter/Realtime access). Tenant resolved from the **operator subdomain** (`tp.` / `teachhq.` / `foodcompliancehq.` / `marchfoods.` `bespokelms.com`) by host middleware.

**Design system — the single source of truth.** Canonical tokens (I recommend a **W3C Design-Tokens / Style Dictionary** JSON source) generating **Tailwind `@theme` for web** and a **Dart theme for Flutter**, so web and app share one token set. **Tokens are extracted from the current approved design** (every colour/spacing/type/radius/shadow), deduped into coherent scales, and named. Components reference tokens only — zero arbitrary values, enforced by lint. New values must be added to the token source before use.

**White-label.** Per-operator `brand_theme` supplies token *overrides* (accent, logo, etc.) injected as CSS custom properties at request time; brand assets in Supabase Storage. Same components, per-tenant skin.

**Real data, real states.** Every dashboard/table/card is Supabase-driven; where data is absent we show loading / empty / zero / unavailable states — never invented records.

**Flutter (later).** Shares the same Supabase backend and Laravel API; Effective Dart + `flutter_lints` + strict null-safety; consumes the shared Dart tokens for visual parity.

---

## 5. Email — Resend (dedicated, isolated from Vows)

Real login needs transactional email (set password, reset, invite, magic link). Plan: **a dedicated `bespokelms.com` sending domain in Resend with its own API key**, wired as **Supabase Auth custom SMTP** (and later the Laravel mailer). This is kept **100% separate from the Wedding Vows** domain/key — different domain, different key, same account is fine. DNS (SPF / DKIM / return-path) is added to `bespokelms.com` in Namecheap without disturbing the existing Netlify web records. *(Being set up now — see chat.)*

---

## 6. Standards & automation (CI gates, not manual review)

- **PHP/Laravel:** Laravel Pint (PSR-12 / PER 3.0), PHPStan/Larastan, Pest tests, Rector (optional).
- **Front-end build:** Prettier (+ Blade plugin) / Biome, Stylelint — token-lint rule to reject raw hex/arbitrary values.
- **SQL:** sqlfluff (Postgres dialect), declarative reversible migrations, snake_case, ISO 8601.
- **Flutter:** `dart format`, `flutter_lints` (+ `very_good_analysis`), `dart analyze`.
- **Accessibility:** axe-core + Lighthouse CI for WCAG 2.2 AA (semantics, headings, ARIA, focus, contrast, 44px targets, text scaling); manual audit per release.
- **Responsive:** mobile-first; views that don't suit small screens (e.g. the compliance matrix below 1280px) show a clear "use a larger screen" message rather than a broken layout.
- **Gate:** GitHub Actions runs all of the above on every PR; merge blocked on failure. Netlify keeps the static reference; the Laravel app deploys to a PHP host.

---

## 7. What carries forward vs what is rebuilt

**Keep (valuable, standards-aligned):** the Supabase schema, RLS, seed, the 4 tenant admins + Marcus Reed, the org-tree/RBAC model, and the *visual design* (as tokens).
**Reference only:** the single-file prototype — the source of truth for *how it should look and behave*, not the implementation.
**Build new:** the Laravel app, the extracted design-token system, tenancy/auth/email wiring, real-data views with proper states, CI.

---

## 8. Recommended sequence (foundation-first, no mock data at any step)

0. **Design tokens + repo standards** — harvest the approved design into a token source; scaffold the repo with Pint/PHPStan/Prettier/sqlfluff + CI; screenshot-diff harness for parity.
1. **Laravel + tenancy + auth + Resend email** — scaffold, subdomain tenant resolution, Supabase-Auth JWT verification, Resend SMTP (password set/reset working).
2. **Parity shell** — header/nav/workspaces rebuilt token-driven, pixel-matched to the prototype, across all breakpoints, light + dark, WCAG 2.2 AA.
3. **Platform (owner) + tenant management on real data** — Marcus logs in, manages the 4 tenants from live `organizations` / compliance views.
4. **My / Team / Admin on real data** — dashboards, library, matrix, saved views → DB, with proper empty/zero states.
5. **Flutter** — shared backend + tokens.

---

## 9. Open decisions I need from you (each has a recommended default)

1. **Auth model** — *Supabase Auth as IdP (recommended: already seeded, shared with Flutter, RLS-native)* vs Laravel Sanctum/Fortify as primary.
2. **Tenancy routing** — *subdomain per operator on bespokelms.com (recommended)* vs path-based (`/t/turner-price`).
3. **Tenant-isolation enforcement** — *custom Eloquent `TenantScope` over the org tree (recommended for a nested model)* vs an off-the-shelf package (spatie/stancl, which assume a flat tenant_id).
4. **Design-token tooling** — *Style Dictionary / W3C tokens generating both Tailwind and Dart (recommended for web+Flutter parity)* vs Tailwind-`@theme`-only for now.
5. **Laravel host** — Forge + VPS, Fly.io, or Laravel Cloud/Vapor (affects deploy + per-tenant subdomains).

Defaults are safe to proceed on; tell me any you want changed.
