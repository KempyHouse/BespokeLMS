-- 269: Proposals & e-signature — core schema.
--
-- The Turner Price SaaS agreement was drafted in Word, approved by email and
-- signed outside any system; the platform's only trace is one file in
-- crm_documents. This migration gives agreements a home: an envelope with an
-- internal co-author approval loop, external signers on a tokened public
-- page, and a hash-chained append-only evidence trail. Executed copies are
-- filed into crm_documents by the application on completion, so the CRM
-- remains the single filing cabinet.
--
-- Design notes:
-- * Versions store the rendered document as canonical HTML in-table
--   (body_html + sha256 over a canonicalised form), matching the
--   product_documents precedent and the "readable where it lives" epic.
--   PDF export is a later, additive capability (no PDF renderer exists in
--   the app today — deliberate; see the epic).
-- * esign_events is append-only in the crm_permissions mould: no update or
--   delete policies, evidence jsonb carries a hashed IP and user-agent
--   family, never a raw IP. Events are hash-chained per document
--   (event_hash = sha256(canonical payload + prev_event_hash)) so tampering
--   is evident.
-- * CRM links are composite FKs onto (id, owning_organization_id) pairs, so
--   an envelope can never point at another tenant's account/contact/deal.
-- * Module key 'esign' via module_enabled(); access mirrors crm_org_access
--   (admin tiers or the 'sales' capability).
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 269_bespokelms_esign_core.

-- ---- Enums ----------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_type where typname = 'esign_document_status') then
    create type esign_document_status as enum
      ('draft','in_review','approved','sent','partially_signed','completed','declined','expired','voided');
  end if;
  if not exists (select 1 from pg_type where typname = 'esign_recipient_role') then
    create type esign_recipient_role as enum ('approver','signer','cc');
  end if;
  if not exists (select 1 from pg_type where typname = 'esign_recipient_status') then
    create type esign_recipient_status as enum ('pending','notified','viewed','completed','declined');
  end if;
  if not exists (select 1 from pg_type where typname = 'esign_event_type') then
    create type esign_event_type as enum
      ('created','version_added','approval_requested','approved','sent','delivered','viewed',
       'otp_passed','signed','declined','reminded','expired','voided','completed','filed');
  end if;
end $$;

-- ---- Access predicate -----------------------------------------------------

create or replace function esign_org_access(org uuid)
returns boolean language sql stable security definer set search_path to 'public'
as $$
  select module_enabled(org, 'esign')
     and exists (
       select 1 from profiles p
       where p.auth_user_id = auth.uid()
         and p.organization_id = org
         and (p.role in ('bespokelms_owner','lms_operator_admin','client_admin')
              or exists (select 1 from profile_capabilities pc
                         where pc.profile_id = p.id and pc.capability = 'sales'))
     );
$$;

revoke execute on function esign_org_access(uuid) from public, anon;
grant execute on function esign_org_access(uuid) to authenticated;

-- ---- Templates ------------------------------------------------------------
-- owning_organization_id null = platform catalogue (cloneable starting
-- points, same pattern as catalogue pathways).

create table if not exists esign_templates (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid references organizations(id) on delete cascade,
  name text not null,
  description text,
  body_html text not null default '',
  merge_manifest jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table esign_templates is 'Reusable proposal/agreement sources with a merge-field manifest. owning_organization_id null = platform catalogue, cloneable per tenant.';

-- ---- Envelopes ------------------------------------------------------------

create table if not exists esign_documents (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references organizations(id) on delete cascade,
  template_id uuid references esign_templates(id) on delete set null,
  title text not null,
  status esign_document_status not null default 'draft',
  current_version_no integer not null default 0,
  account_id uuid,
  contact_id uuid,
  deal_id uuid,
  expires_at timestamptz,
  reminder_days integer,
  sent_at timestamptz,
  completed_at timestamptz,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint esign_documents_account_org
    foreign key (account_id, owning_organization_id)
    references crm_accounts (id, owning_organization_id) on delete set null (account_id),
  constraint esign_documents_contact_org
    foreign key (contact_id, owning_organization_id)
    references crm_contacts (id, owning_organization_id) on delete set null (contact_id),
  constraint esign_documents_deal_org
    foreign key (deal_id, owning_organization_id)
    references crm_deals (id, owning_organization_id) on delete set null (deal_id)
);

create index if not exists esign_documents_org_status on esign_documents (owning_organization_id, status);
create index if not exists esign_documents_account on esign_documents (account_id) where account_id is not null;
create index if not exists esign_documents_contact on esign_documents (contact_id) where contact_id is not null;
create index if not exists esign_documents_deal on esign_documents (deal_id) where deal_id is not null;

comment on table esign_documents is 'The e-signature envelope: one document moving through co-author approval and client signature. CRM links are pinned to the same owning organisation by composite FKs.';

-- ---- Immutable versions ---------------------------------------------------

create table if not exists esign_document_versions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign_documents(id) on delete cascade,
  version_no integer not null,
  body_html text not null,
  sha256 text not null,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint esign_versions_unique unique (document_id, version_no),
  constraint esign_versions_sha_shape check (sha256 ~ '^[0-9a-f]{64}$')
);

comment on table esign_document_versions is 'Immutable rendered snapshots. Approvals and signatures pin to a version; a new version voids outstanding approvals and signing links. sha256 is over the canonicalised body.';

-- ---- Recipients -----------------------------------------------------------

create table if not exists esign_recipients (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign_documents(id) on delete cascade,
  role esign_recipient_role not null,
  profile_id uuid references profiles(id) on delete set null,
  contact_id uuid references crm_contacts(id) on delete set null,
  name text not null,
  email text not null,
  signing_order integer not null default 1,
  status esign_recipient_status not null default 'pending',
  token_hash text,
  token_expires_at timestamptz,
  otp_required boolean not null default false,
  otp_hash text,
  otp_expires_at timestamptz,
  signature_kind text check (signature_kind in ('typed','drawn')),
  signature_data text,
  viewed_at timestamptz,
  completed_at timestamptz,
  declined_reason text,
  created_at timestamptz not null default now(),
  constraint esign_recipients_approver_profile
    check (role <> 'approver' or profile_id is not null)
);

create index if not exists esign_recipients_document on esign_recipients (document_id, role, signing_order);
create unique index if not exists esign_recipients_token on esign_recipients (token_hash) where token_hash is not null;

comment on table esign_recipients is 'Participants on an envelope. Approvers are internal profiles; signers/cc are external (CRM contact or ad-hoc email snapshot). token_hash is the SHA-256 of a single-use signing token — the raw token is never stored.';

-- ---- Append-only, hash-chained evidence -----------------------------------

create table if not exists esign_events (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references esign_documents(id) on delete cascade,
  recipient_id uuid references esign_recipients(id) on delete set null,
  event esign_event_type not null,
  actor_profile_id uuid references profiles(id) on delete set null,
  version_no integer,
  statement text,
  evidence jsonb not null default '{}'::jsonb,
  prev_event_hash text,
  event_hash text not null,
  occurred_at timestamptz not null default now(),
  constraint esign_events_hash_shape check (event_hash ~ '^[0-9a-f]{64}$')
);

create index if not exists esign_events_document on esign_events (document_id, occurred_at);

comment on table esign_events is 'Append-only evidence trail, hash-chained per document (event_hash covers the canonical payload plus prev_event_hash). evidence carries hashed IP and user-agent family — never a raw IP. No update or delete policies exist by design.';

-- ---- Row level security ---------------------------------------------------

alter table esign_templates enable row level security;
alter table esign_documents enable row level security;
alter table esign_document_versions enable row level security;
alter table esign_recipients enable row level security;
alter table esign_events enable row level security;

-- Templates: tenant rows under the module gate; platform-catalogue rows
-- readable by any org that has the module; only the platform owner writes
-- the catalogue.
drop policy if exists esign_templates_org on esign_templates;
create policy esign_templates_org on esign_templates
  for all
  using (
    (owning_organization_id is not null and esign_org_access(owning_organization_id))
    or (owning_organization_id is null and is_active and exists (
          select 1 from profiles p
          where p.auth_user_id = auth.uid() and module_enabled(p.organization_id, 'esign')))
  )
  with check (
    (owning_organization_id is not null and esign_org_access(owning_organization_id))
    or (owning_organization_id is null and exists (
          select 1 from profiles p
          where p.auth_user_id = auth.uid() and p.role = 'bespokelms_owner'))
  );

drop policy if exists esign_documents_org on esign_documents;
create policy esign_documents_org on esign_documents
  for all using (esign_org_access(owning_organization_id))
  with check (esign_org_access(owning_organization_id));

drop policy if exists esign_versions_org on esign_document_versions;
create policy esign_versions_org on esign_document_versions
  for all using (exists (select 1 from esign_documents d
                         where d.id = document_id and esign_org_access(d.owning_organization_id)))
  with check (exists (select 1 from esign_documents d
                      where d.id = document_id and esign_org_access(d.owning_organization_id)));

drop policy if exists esign_recipients_org on esign_recipients;
create policy esign_recipients_org on esign_recipients
  for all using (exists (select 1 from esign_documents d
                         where d.id = document_id and esign_org_access(d.owning_organization_id)))
  with check (exists (select 1 from esign_documents d
                      where d.id = document_id and esign_org_access(d.owning_organization_id)));

-- Events: SELECT and INSERT only — the trail cannot be edited or thinned.
drop policy if exists esign_events_read on esign_events;
create policy esign_events_read on esign_events
  for select using (exists (select 1 from esign_documents d
                            where d.id = document_id and esign_org_access(d.owning_organization_id)));

drop policy if exists esign_events_append on esign_events;
create policy esign_events_append on esign_events
  for insert with check (exists (select 1 from esign_documents d
                                 where d.id = document_id and esign_org_access(d.owning_organization_id)));
