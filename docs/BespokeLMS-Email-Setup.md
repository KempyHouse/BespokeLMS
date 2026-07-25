# BespokeLMS — Email setup (Resend + Supabase Auth)

BespokeLMS sends two distinct kinds of email, and they are configured in two
different places. Keeping them straight matters, because a learner who gets a
password-reset from `supabase.co` and a course reminder from `bespokelms.com`
sees an inconsistent brand.

**1. Application mail** — course reminders, certificates, notifications, and the
"send test" action. This is sent by Laravel through the transport configured in
the app at **Platform → Email Integration**. The enabled provider row is the
platform transport; the runtime mailer decrypts its secret, sends on it, and
applies the sending tenant's alias. Nothing here needs `.env` changes once a
provider is enabled and given a key.

**2. Auth mail** — sign-up confirmation, magic links, and password recovery.
This is sent by **Supabase Auth (GoTrue)**, not by Laravel, so it is configured
in the Supabase dashboard, not in the app. Point it at the same Resend domain so
it matches everything else.

## One-time Resend setup

1. In Resend, add and verify a dedicated sending domain for the platform — the
   plan is `bespokelms.com` (or a `mail.bespokelms.com` subdomain to keep
   sending DNS separate from the apex). Add the SPF, DKIM and (recommended)
   DMARC records Resend shows you at the domain's DNS (Namecheap). Wait for
   Resend to report the domain as **Verified**.
2. Create an API key scoped to that domain. This single key is the secret for
   both paths below. Store it only as a secret — never in the repo.

## Wire application mail (Laravel, via the console)

1. Go to **Platform → Email Integration**.
2. On the **Resend** card: tick "Use as the platform transport", paste the API
   key, set the default "from" name/address (e.g. `BespokeLMS` /
   `no-reply@bespokelms.com`) and the sending domain, then Save. (You'll be
   asked to confirm your password — this is the step-up re-auth.)
3. Click **Send test email**. A test goes to your own address on the Resend
   transport; a row is written to `email_send_logs`.

The runtime sends over Resend's SMTP relay (`smtp.resend.com`, user `resend`,
password = the API key), so no extra Composer package is required. Switching
provider later is just enabling a different card and adding that provider's key —
no code change. (Postmark and SMTP work the same way. Amazon SES needs its
dedicated *SMTP credentials*, which differ from AWS API keys — generate them in
the SES console and put the SMTP username + password on the SES card.)

For the service-role-key-backed features (this console, audit log, delivery
logs) to work, `SUPABASE_SERVICE_ROLE_KEY` must be set in the app environment
(it is intentionally blank in local `.env`). `APP_KEY` is what encrypts the
stored provider secret, so it must be stable across app instances.

## Wire auth mail (Supabase Auth → Resend)

In the Supabase dashboard for project `pqmdtqsscyltykgcwwus`:

1. **Authentication → Emails → SMTP settings** → enable **Custom SMTP**.
2. Enter:
   - Host: `smtp.resend.com`
   - Port: `465` (SSL) or `587` (STARTTLS)
   - Username: `resend`
   - Password: the Resend API key
   - Sender email: `no-reply@bespokelms.com`  ·  Sender name: `BespokeLMS`
3. Save, then send yourself a password reset from the app to confirm it now
   arrives from the BespokeLMS domain rather than the default Supabase sender.

Note: there is an existing open item (see `bespokelms_password_reset`) that the
app's `/forgot-password` flow doesn't yet call Supabase `recover`; custom SMTP
here fixes the *branding* of GoTrue mail, but that flow still needs wiring for
the app-initiated reset to actually send.

## Where each piece lives

- Provider transport (owner-level, swappable): `email_integrations` table +
  Platform → Email Integration.
- Tenant sender identity (per tenant): `tenant_email_aliases` + each tenant's
  console (Email sender section).
- Delivery history: `email_send_logs` (recipient stored as domain only).
- Auth mail branding: Supabase dashboard → Authentication → SMTP.
