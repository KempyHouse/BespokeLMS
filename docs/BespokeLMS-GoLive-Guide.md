# BespokeLMS — Go-live guide (Coming Soon + login)

**Goal:** `bespokelms.com` shows the Coming Soon page with the Marcus Reed sign-in, and the app (dashboard) sits behind that login.

---

## First, the one fact that changes everything

Your domain's **nameservers are Namecheap's** (`dns1.registrar-servers.com` / `dns2.registrar-servers.com`), confirmed by a live lookup. So **every DNS change goes in Namecheap**, at:

**Namecheap → Domain List → `bespokelms.com` → Manage → Advanced DNS.**

Netlify's "already on Netlify DNS" message was misleading — ignore it. Netlify only *hosts*; Namecheap *resolves*.

> Whenever you edit Advanced DNS, **leave the Freshworks (`myfreshworks.com`), Freshdesk (`support`), and Google verification records untouched.** Only add/adjust the records below.

---

## Path A — Get it live now (recommended, ~5 minutes)

This puts the Coming Soon + login on `bespokelms.com` using your existing **`bespokelms-app`** Netlify project. The dashboard stays reachable behind the login. No second site needed.

### Step 1 — Publish the page
The Coming Soon file is already sitting in your repo folder. In a terminal:

```bash
cd C:\Claude\BespokeLMS
git add index.html
git commit -m "Coming soon + login gateway"
git push
```

Netlify auto-deploys in ~1 minute. Check `https://bespokelms-app.netlify.app` — it should now show the Coming Soon page.

### Step 2 — Make the domain resolve (Namecheap → Advanced DNS)
`bespokelms.com` + `www` are already attached to `bespokelms-app` in Netlify. Now fix the records so they actually point there:

1. **`www`** — find the existing `CNAME` for host `www` and change its **Value** to:
   `bespokelms-app.netlify.app`
   *(it currently points at `bespokelms.netlify.app`, an old deleted site — that's why it fails).*
2. **Apex** — make sure there is a record: **Type** `ALIAS Record`, **Host** `@`, **Value** `apex-loadbalancer.netlify.com`, **TTL** Automatic. *(If a stale `@` record exists, delete it and keep just this one.)*

Save. DNS propagates in a few minutes (occasionally up to an hour).

### Step 3 — Turn on HTTPS
Netlify → **bespokelms-app → Domain management → HTTPS**. Once `bespokelms.com` and `www` show green (not "propagating"), click **Force HTTPS**.

✅ Done: `bespokelms.com` → Coming Soon + login → (on sign-in) the app.

---

## Path B — The full split (for when you build the marketing site)

End state: `bespokelms.com` + `www` = **marketing**, `app.bespokelms.com` = **the app**.

### B1 — Put the app on `app.bespokelms.com`
1. **Netlify → bespokelms-app → Domain management:** remove `bespokelms.com` and `www.bespokelms.com`, then **Add domain → `app.bespokelms.com`**.
2. **Namecheap → Advanced DNS:** add `CNAME`, Host `app`, Value `bespokelms-app.netlify.app`.
3. **Restore the app's own homepage** (undo the Coming Soon on this repo so the app root is the app again):
   ```bash
   cd C:\Claude\BespokeLMS
   git checkout index.html
   git push
   ```

### B2 — Put the marketing (Coming Soon) on `bespokelms.com` + `www`
1. Copy the Coming Soon file into its **own empty folder** (e.g. `C:\Claude\BespokeLMS-Marketing\index.html`). *(Ask me and I'll hand you a clean copy.)*
2. Go to **https://app.netlify.com/drop** and drag that folder in → it creates a new site.
3. Rename it: that site → **Site configuration → Change site name** → e.g. `bespokelms-marketing`.
4. That site → **Domain management → Add domain** → `bespokelms.com`, then `www.bespokelms.com`.
5. **Namecheap → Advanced DNS:**
   - Apex: `ALIAS`, Host `@`, Value `apex-loadbalancer.netlify.com`.
   - `www`: change the `CNAME` Value to `bespokelms-marketing.netlify.app` (the new site's address).

### B3 — Point the login at the app
The Coming Soon sign-in currently lands on the prototype URL. Once `app.bespokelms.com` is live, tell me and I'll switch the redirect to `https://app.bespokelms.com` (one-line change) and you redeploy the marketing site.

### B4 — HTTPS on both
Force HTTPS on **both** the app project and the marketing site (Domain management → HTTPS), once each shows green.

---

## Namecheap records — quick reference

| Purpose | Type | Host | Value |
|---|---|---|---|
| Site — apex (both paths) | ALIAS | `@` | `apex-loadbalancer.netlify.com` |
| Path A — www → app project | CNAME | `www` | `bespokelms-app.netlify.app` |
| Path B — app subdomain | CNAME | `app` | `bespokelms-app.netlify.app` |
| Path B — www → marketing | CNAME | `www` | `bespokelms-marketing.netlify.app` |

*(Netlify also shows the exact records under each site's Domain management if you ever want to double-check.)*

---

## Not part of go-live, but queued (email — all in the same Advanced DNS)
- Add the 5 `send.bespokelms.com` Resend records (sending + receiving) — copy the DKIM value straight from the Resend domain page.
- `support@bespokelms.com` → email forwarding to your inbox (Namecheap → **Mail Settings → Email Forwarding**).
- Remove the two SendGrid records (`CNAME 28805639` and `CNAME fwtrack1`, both → `sendgrid.net`).

Say the word and I'll walk you through those, or drive them for you.
