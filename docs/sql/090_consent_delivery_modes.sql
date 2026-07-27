-- 090: how consent is delivered becomes the tenant's choice. APPLIED.
--
-- One banner does not fit every site, because sites do not all have the same
-- legal position. Three modes on consent_sites.delivery_mode:
--
--   banner     The full ask: accept / reject as equals, per-purpose choices,
--              blocking until answered. The default, and the safest.
--
--   notice     A notice with one acknowledgement, recorded as action
--              'acknowledge'. For sites whose only cookies are essential or
--              fall under regional opt-out rules - where there is nothing to
--              consent TO, and a consent ceremony would be theatre.
--
--   link_only  No interruption at all. Nothing non-essential loads until the
--              visitor opens the preference centre from the footer link (the
--              runtime shows its floating control if the site has no link).
--
-- What is NOT a choice: blocking stays fail-closed in every mode, the ledger
-- records in every mode, and reject never becomes harder than accept.
-- Flexibility is for delivery, not for the floor. The chosen mode travels in
-- the frozen config document, so the evidence of what a visitor was shown
-- includes HOW they were asked.
--
-- Alongside this migration (in code): hosted web sites auto-inject the
-- loader first in <head> when a consent site is linked (zero installation),
-- and the 'cookie-policy' CMS block renders the declared purposes and
-- vendors - the policy, the banner and the blocking engine are one
-- configuration that cannot disagree with itself.

alter table public.consent_sites
  add column if not exists delivery_mode text not null default 'banner'
    check (delivery_mode in ('banner', 'notice', 'link_only'));
