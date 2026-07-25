-- 084: marketing permissions, and the ability to withdraw one.
--
-- WHAT WAS THERE BEFORE. crm_contacts.do_not_contact, a single boolean, and a
-- send-time check against it. That is an opt-OUT list, and it answers the
-- question "has this person told us to stop?" — which is not the question the
-- law asks. UK PECR reg 22 asks whether the person CONSENTED to receive
-- electronic mail, or whether the soft opt-in applies. "They are not on our
-- suppression list" is not an answer to that, and it is not evidence of
-- anything if the ICO asks.
--
-- So permissions are recorded, per channel, with the lawful basis, the source,
-- the time, and — the part everybody forgets — THE EXACT WORDS THE PERSON WAS
-- SHOWN. A record that somebody consented, without a record of what they were
-- consenting to, proves nothing.
--
-- APPEND-ONLY, for the same reason consent_records is: this is the table that
-- gets produced in an argument. There are no UPDATE or DELETE policies, so a
-- withdrawal is a new row and the history is intact by construction rather
-- than by anyone remembering to keep it. do_not_contact stays where it is: it
-- is a global suppression switch, which is a different and coarser thing, and
-- erasure already relies on it.

create type crm_permission_channel as enum ('email', 'phone', 'sms', 'post');

create type crm_permission_state as enum ('granted', 'refused', 'withdrawn');

-- Not every lawful basis is consent, and pretending otherwise is its own
-- compliance failure: a tenant emailing existing customers about a similar
-- product under the soft opt-in is entitled to do so, and mislabelling that as
-- consent would mean claiming evidence that does not exist.
create type crm_permission_basis as enum ('consent', 'soft_opt_in', 'legitimate_interest');

create table public.crm_permissions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  contact_id uuid not null references public.crm_contacts(id) on delete cascade,
  channel crm_permission_channel not null,
  state crm_permission_state not null,
  basis crm_permission_basis not null,

  -- The wording shown at the point of collection.
  statement text,

  -- web_form | import | manual | unsubscribe | api
  source text not null,
  source_reference text,

  -- Submission id, page path, hashed IP, user-agent family. Never a raw IP:
  -- the address is what makes this a bigger disclosure than the permission it
  -- is evidence for.
  evidence jsonb not null default '{}'::jsonb,

  occurred_at timestamptz not null default now(),
  recorded_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),

  -- The soft opt-in exists only for electronic mail. Applying it to a phone
  -- call or a letter is not a lawful basis, it is a mistake, and it is the
  -- sort of mistake that is easier to make in a dropdown than to notice in an
  -- audit.
  constraint crm_permissions_soft_opt_in_is_electronic
    check (basis <> 'soft_opt_in' or channel in ('email', 'sms')),

  -- Consent with no record of what was consented to is not evidence. The
  -- database refuses it rather than storing a permission that cannot be
  -- defended.
  constraint crm_permissions_consent_needs_wording
    check (state <> 'granted' or basis <> 'consent' or (statement is not null and length(btrim(statement)) > 0))
);

create index crm_permissions_lookup on public.crm_permissions (contact_id, channel, occurred_at desc);
create index crm_permissions_org on public.crm_permissions (organization_id, occurred_at desc);

alter table public.crm_permissions enable row level security;

-- Same reach as the contact the permission belongs to; no wider.
create policy crm_permissions_select on public.crm_permissions
  for select using (crm_org_access(organization_id));

create policy crm_permissions_insert on public.crm_permissions
  for insert with check (crm_org_access(organization_id));

-- No UPDATE policy and no DELETE policy. That absence IS the append-only
-- guarantee: it does not depend on the application behaving.

/*
 * The current answer for one contact and channel.
 *
 * security_invoker so the view enforces the caller's row-level security rather
 * than the view owner's. Without it this would be a way to read every tenant's
 * permissions through a view on a table that carefully prevents exactly that.
 */
create view public.crm_permissions_current
with (security_invoker = true) as
select distinct on (contact_id, channel)
  id, organization_id, contact_id, channel, state, basis, statement,
  source, source_reference, occurred_at, recorded_by
from public.crm_permissions
order by contact_id, channel, occurred_at desc, created_at desc;

/*
 * The unsubscribe token.
 *
 * Opaque, per contact, and stable: an email read six months from now must
 * still unsubscribe. Deliberately NOT a signed URL — those break for every
 * message ever sent the moment the application key is rotated, and a rotation
 * that silently disables every unsubscribe link in the wild is a compliance
 * incident produced by an operations task.
 *
 * The token is not a credential for anything else. The worst a leaked one does
 * is unsubscribe somebody, which fails in the safe direction, and the page it
 * opens deliberately does not display the address it belongs to.
 */
alter table public.crm_contacts
  add column if not exists unsubscribe_token text;

update public.crm_contacts
   set unsubscribe_token = replace(replace(encode(gen_random_bytes(24), 'base64'), '+', '-'), '/', '_')
 where unsubscribe_token is null;

alter table public.crm_contacts
  alter column unsubscribe_token set default replace(replace(encode(gen_random_bytes(24), 'base64'), '+', '-'), '/', '_');

alter table public.crm_contacts
  alter column unsubscribe_token set not null;

create unique index if not exists crm_contacts_unsubscribe_token
  on public.crm_contacts (unsubscribe_token);
