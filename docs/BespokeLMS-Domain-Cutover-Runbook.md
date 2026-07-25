# BespokeLMS — Domain cutover runbook (Phase 1)

**Date:** 25 July 2026 · **Status:** deployed (`43f3739` pushed and live on app.bespokelms.com); the steps below are yours to run
**Applies to:** `app.bespokelms.com`, `www.bespokelms.com`, `bespokelms.com`

Phase 1 of the Website & Consent module is built: one Laravel application can now serve the LMS, a
marketing website and (later) a support portal from different hostnames. What remains is DNS and
platform configuration, which only you can do.

---

## What is already done

| | |
|---|---|
| **Schema** | `tenant_domains` (migration 044) applied to Supabase, RLS on, owner-only writes |
| **Seed** | `app.bespokelms.com`, `www.bespokelms.com`, `bespokelms.com` (apex → www) seeded **unverified** |
| **Middleware** | `App\Http\Middleware\ResolveHost`, global, runs before routing |
| **Public surface** | `routes/site.php` + `SiteController` + `layouts.public` + a token-styled holding page |
| **Console** | Platform → Website & Consent → **Domains** (`/platform/domains`) |
| **Menu** | Platform rail v8 published: Website & Consent now carries Sites, Pages, Navigation, Forms, Media, Redirects, Domains, Support Portal, Cookie Banner, Purposes & Vendors, Cookie Scans, Consent Records |
| **Tests** | `tests/Feature/HostResolutionTest.php`, 7 cases, passing alongside the existing suite |

**Nothing is routed yet.** Every seeded host is unverified, and an unverified host is ignored by the
resolver, so today the application behaves exactly as it did before.

---

## Step 1 — Push and deploy

The app repository has uncommitted work from this session (see `git status`). Push it, let Laravel
Cloud deploy, then run once on the deployed app:

```
php artisan nav:sync-registry
```

That fills in the icons and descriptions for the ten new registry entries. The menu items already
exist and already point at the right keys, so the only visible change is that the icons appear.

**Check after deploy, before touching DNS:**

- The application still loads normally on its current hostname.
- Platform → Website & Consent → **Domains** renders and lists the three seeded hosts.
- Nothing else in the rail has moved except Support Portal (now under Website & Consent) and
  Live Chat (now under Communication).

If anything looks wrong, nothing has been cut over — you can roll the menu back in one click
(Navigation Menus → platform-rail → rollback to version 6) and revert the deploy.

---

## Step 2 — Environment

Add to the deployed environment:

```
TENANCY_APP_HOSTS=localhost,127.0.0.1,::1,<laravel-cloud-internal-hostname>
TENANCY_STRICT_HOSTS=false
TENANCY_SITE_INDEXABLE=false
```

`TENANCY_APP_HOSTS` should include whatever hostname Laravel Cloud uses for internal health checks
(the `*.laravel.cloud` deployment hostname), so that path never depends on a database lookup. Do NOT
put `app.bespokelms.com` in it — that host is a real `tenant_domains` row, and resolving it properly
is what gives the request its tenant context. Keep `TENANCY_STRICT_HOSTS=false` until step 5.

Deployment state as at 25 July 2026: the app runs on Laravel Cloud (org `kemp.house`, app
`bespokelms-app`, environment `production`, EU West Ireland), deploying from `KempyHouse/BespokeLMS-app`
`main`, with `app.bespokelms.com` already attached and verified.

---

## Step 3 — DNS (Namecheap, not Netlify)

`bespokelms.com` is on Namecheap nameservers (`dns1/dns2.registrar-servers.com`). Netlify's
"already on Netlify DNS" message is misleading — every record goes in
**Namecheap → Domain List → bespokelms.com → Advanced DNS**.

Leave the Freshworks, Freshdesk (`support`) and Google-verification records alone.

**Add the three verification records first** (they are safe — they route no traffic):

| Type | Host | Value |
|---|---|---|
| TXT | `_bespokelms-verify.app` | *(token shown next to app.bespokelms.com in the Domains console)* |
| TXT | `_bespokelms-verify.www` | *(token shown next to www.bespokelms.com)* |
| TXT | `_bespokelms-verify` | *(token shown next to bespokelms.com)* |

Then in **Platform → Domains**, press **Check DNS** on each row. A row only starts routing once it
turns Verified — that is deliberate, and it is what closes the subdomain-takeover hole.

**Then point the hostnames at the application:**

| Type | Host | Value | Notes |
|---|---|---|---|
| CNAME | `app` | — | **Already done.** `app.bespokelms.com` is an existing verified custom domain on Laravel Cloud and is serving the app today |
| CNAME | `www` | *(Laravel Cloud target)* | replaces the dead `bespokelms.netlify.app` record |
| ALIAS/A | `@` | *(Laravel Cloud target, or their apex address)* | apex → 301 → www |

Add `www.bespokelms.com` and `bespokelms.com` as custom domains in Laravel Cloud first so certificates
are issued; DNS and the certificate need to agree before traffic arrives. Nothing about `app.` changes —
it keeps working throughout, and verifying its row in the Domains console only adds tenant context to
the resolver, not new behaviour.

---

## Step 4 — Repoint the login redirect

The current coming-soon page at `C:\Claude\BespokeLMS\index.html` has a login modal that redirects to
a hard-coded Netlify URL (`bespokelms-app.netlify.app/teachhq-dashboard-tailwind.html`). Once
`app.bespokelms.com` is live, that string must change to `https://app.bespokelms.com` — or the page
should be retired, since `www` will now serve the holding page from the application itself.

Also update in the deployed environment:

```
APP_URL=https://app.bespokelms.com
SUPABASE_REDIRECT_URL=https://app.bespokelms.com/reset-password
```

and add `https://app.bespokelms.com/reset-password` to the Supabase Auth redirect allow-list, or
password resets will bounce.

---

## Step 5 — Close the door

Once all three hosts show **Verified** and both surfaces are confirmed working:

```
TENANCY_STRICT_HOSTS=true
```

An unrecognised hostname then returns 404 instead of quietly serving the application. This is the
correct end state for a white-label platform: serving the wrong tenant's brand is a brand incident
and a data incident at the same time. Do not set it earlier — an unverified host would take the app
offline on that hostname.

---

## Verifying

| Check | Expected |
|---|---|
| `https://app.bespokelms.com/` | the LMS, sign-in page when signed out |
| `https://www.bespokelms.com/` | the holding page, dark brand tokens, "Log in" pointing at `app.` |
| `https://bespokelms.com/` | 301 to `https://www.bespokelms.com/` |
| `https://www.bespokelms.com/robots.txt` | `Disallow: /` while `TENANCY_SITE_INDEXABLE=false` |
| `https://www.bespokelms.com/anything` | 404 (the CMS phase adds real pages) |
| `https://www.bespokelms.com/_s` | 404 — the internal prefix is never reachable from outside |
| An unknown hostname pointed at the app | serves the application while strict mode is off; 404 after |

---

## Rolling back

- **Menu:** Navigation Menus → platform-rail → rollback to version 6. Version 7 (the two moves) and
  version 8 (the new destinations) are both retained as superseded.
- **Routing:** delete a row in Platform → Domains, or just clear its verification. An unverified host
  is ignored, so removing verification is a complete, instant rollback of host routing.
- **Code:** revert the deploy. The middleware fails to the application surface on any error, so even
  a broken Supabase connection leaves the LMS reachable.
- **Schema:** `drop table tenant_domains; drop type domain_surface;` — nothing else references it.

---

## Notes for whoever picks this up next

- The public surface is served by **rewriting the request path** under `/_s` in global middleware
  before the router matches. That is why `ResolveHost` is in the global stack rather than the `web`
  group, and it is route-cache safe.
- Host lookups are cached for 10 minutes under `domain:<hostname>`. Every write in the Domains
  console forgets the key, so verification takes effect immediately.
- Sessions are host-scoped (`SESSION_DOMAIN` stays unset), so the marketing site and the application
  do not share a session. That is deliberate: the public surface is anonymous, and "Log in" is a
  plain link to the application host.
- `dns_get_record()` does the verification check. If Laravel Cloud blocks outbound DNS, verification
  will always fail — in that case add a manual override to the console rather than weakening the
  rule that unverified hosts do not route.
