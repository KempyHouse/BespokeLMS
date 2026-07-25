-- 029: Sales CRM core — accounts, contacts, junction, timeline, documents.
-- APPLIED to Supabase project pqmdtqsscyltykgcwwus on 2026-07-25 as
-- migration `bespokelms_crm_core_029` (via the Supabase MCP connector).
-- RLS isolation PROVEN live: owner insert/read own-org only; TP admin
-- (module off) sees zero rows and has no access either direction.
--
-- Isolation model (deliberately STRICTER than the rest of the platform):
-- every CRM table carries owning_organization_id (the tenant whose CRM it
-- is) and RLS compares it EXACTLY to the caller's organisation — never
-- org_and_descendants(). The platform owner sees only the BespokeLMS org's
-- own CRM. Each tenant is the data controller of its CRM space; BespokeLMS
-- is a processor for tenant CRM data, so cross-tenant reads are prohibited
-- by design, not by UI.
--
-- Composite FKs (child owning_organization_id must match the parent's) make
-- cross-org references unrepresentable at the database layer.

-- ---- Enums ----------------------------------------------------------------

create type crm_lifecycle_stage as enum
  ('lead','marketing_qualified','sales_qualified','opportunity','customer','churned','partner');

create type crm_activity_type as enum
  ('note','call','email','meeting','task','sms','whatsapp','document','system');

create type crm_activity_direction as enum ('inbound','outbound','internal');

create type crm_record_source as enum
  ('manual','import_freshsales','import_csv','web_form','auto_link','api','sync');

-- ---- Access predicate -----------------------------------------------------

-- True when the calling user belongs to EXACTLY this organisation, the
-- organisation has the sales_crm module enabled, and the user is either an
-- admin tier or holds the 'sales' capability. No subtree traversal.
create or replace function crm_org_access(org uuid)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select module_enabled(org, 'sales_crm')
     and exists (
       select 1 from profiles p
       where p.auth_user_id = auth.uid()
         and p.organization_id = org
         and (
           p.role in ('bespokelms_owner','lms_operator_admin','client_admin')
           or exists (
             select 1 from profile_capabilities pc
             where pc.profile_id = p.id and pc.capability = 'sales'
           )
         )
     );
$$;

revoke execute on function crm_org_access(uuid) from public, anon;
grant execute on function crm_org_access(uuid) to authenticated;

-- ---- Accounts -------------------------------------------------------------

create table crm_accounts (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references organizations(id) on delete cascade,
  organization_id uuid references organizations(id) on delete set null,
  name text not null,
  legal_name text,
  website_domain text,
  industry text,
  employee_band text,
  lifecycle_stage crm_lifecycle_stage not null default 'lead',
  owner_profile_id uuid references profiles(id) on delete set null,
  source crm_record_source not null default 'manual',
  source_detail text,
  phone text,
  address_line1 text,
  address_line2 text,
  address_city text,
  address_region text,
  address_postcode text,
  address_country text,
  description text,
  archived_at timestamptz,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_accounts_org_pair unique (id, owning_organization_id)
);

comment on table crm_accounts is 'CRM relationship records for companies/organisations, scoped to the owning tenant''s CRM. Separate from operational organizations; organization_id is the optional promotion link when an account becomes (or already is) a tenant.';
comment on column crm_accounts.organization_id is 'Promotion link: the operational tenant this account corresponds to (e.g. March Foods). Null for accounts that are not tenants.';

create index crm_accounts_owner_org_idx on crm_accounts (owning_organization_id, name);
create index crm_accounts_lifecycle_idx on crm_accounts (owning_organization_id, lifecycle_stage);
create index crm_accounts_name_trgm_idx on crm_accounts using gin (name gin_trgm_ops);
create index crm_accounts_promoted_idx on crm_accounts (organization_id) where organization_id is not null;

-- ---- Contacts -------------------------------------------------------------

create table crm_contacts (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references organizations(id) on delete cascade,
  first_name text not null,
  last_name text not null,
  email text,
  phone text,
  mobile text,
  job_title text,
  lifecycle_stage crm_lifecycle_stage not null default 'lead',
  owner_profile_id uuid references profiles(id) on delete set null,
  source crm_record_source not null default 'manual',
  source_detail text,
  profile_id uuid references profiles(id) on delete set null,
  profile_linked_at timestamptz,
  profile_link_method text check (profile_link_method in ('auto_email_match','manual')),
  do_not_contact boolean not null default false,
  notes text,
  archived_at timestamptz,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_contacts_org_pair unique (id, owning_organization_id)
);

comment on table crm_contacts is 'CRM person records, scoped to the owning tenant''s CRM. A person may exist in several tenants'' CRMs — each tenant is a separate controller, so there is deliberately NO cross-tenant dedup or shared person record.';
comment on column crm_contacts.profile_id is 'Auto-detected or manually confirmed link to a platform user profile (contact became a user). Set only within legitimate ownership boundaries; see the auto-link job.';
comment on column crm_contacts.do_not_contact is 'Hard objection stop, distinct from consent. Consent truth lives in the (future) consent module; enforcement happens at send time in the outbound module.';

create unique index crm_contacts_email_unique
  on crm_contacts (owning_organization_id, lower(email))
  where email is not null and archived_at is null;
create index crm_contacts_owner_org_idx on crm_contacts (owning_organization_id, last_name, first_name);
create index crm_contacts_lifecycle_idx on crm_contacts (owning_organization_id, lifecycle_stage);
create index crm_contacts_profile_idx on crm_contacts (profile_id) where profile_id is not null;

-- ---- Account <-> Contact junction ----------------------------------------

create table crm_account_contacts (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references organizations(id) on delete cascade,
  account_id uuid not null,
  contact_id uuid not null,
  role_at_account text,
  is_primary boolean not null default false,
  started_on date,
  ended_on date,
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint crm_account_contacts_unique unique (account_id, contact_id),
  constraint crm_account_contacts_account_fk
    foreign key (account_id, owning_organization_id)
    references crm_accounts (id, owning_organization_id) on delete cascade,
  constraint crm_account_contacts_contact_fk
    foreign key (contact_id, owning_organization_id)
    references crm_contacts (id, owning_organization_id) on delete cascade,
  constraint crm_account_contacts_dates check (ended_on is null or started_on is null or ended_on >= started_on)
);

comment on table crm_account_contacts is 'Many-to-many: people work at companies; one person may work at several accounts and an account has many contacts. Composite FKs pin both sides to the same owning organisation.';

create index crm_account_contacts_account_idx on crm_account_contacts (account_id);
create index crm_account_contacts_contact_idx on crm_account_contacts (contact_id);

-- ---- Activities (the communication timeline) ------------------------------

create table crm_activities (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references organizations(id) on delete cascade,
  activity_type crm_activity_type not null,
  direction crm_activity_direction,
  subject text not null,
  body text,
  happened_at timestamptz not null default now(),
  due_at timestamptz,
  completed_at timestamptz,
  actor_profile_id uuid references profiles(id) on delete set null,
  account_id uuid,
  contact_id uuid,
  channel_refs jsonb not null default '{}'::jsonb,
  source crm_record_source not null default 'manual',
  created_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint crm_activities_anchor check (account_id is not null or contact_id is not null),
  constraint crm_activities_account_fk
    foreign key (account_id, owning_organization_id)
    references crm_accounts (id, owning_organization_id) on delete cascade,
  constraint crm_activities_contact_fk
    foreign key (contact_id, owning_organization_id)
    references crm_contacts (id, owning_organization_id) on delete cascade,
  constraint crm_activities_task_fields check (activity_type = 'task' or (due_at is null and completed_at is null))
);

comment on table crm_activities is 'The per-account/contact communication timeline: notes, calls, emails, meetings, tasks, system events. This IS personal data (unlike email_send_logs, which stays PII-free) — retention and erasure apply here. channel_refs holds provider message ids, never duplicated bodies.';

create index crm_activities_org_time_idx on crm_activities (owning_organization_id, happened_at desc);
create index crm_activities_account_idx on crm_activities (account_id, happened_at desc) where account_id is not null;
create index crm_activities_contact_idx on crm_activities (contact_id, happened_at desc) where contact_id is not null;
create index crm_activities_open_tasks_idx on crm_activities (owning_organization_id, due_at)
  where activity_type = 'task' and completed_at is null;

-- ---- Documents ------------------------------------------------------------

create table crm_documents (
  id uuid primary key default gen_random_uuid(),
  owning_organization_id uuid not null references organizations(id) on delete cascade,
  storage_path text not null,
  file_name text not null,
  mime_type text not null,
  byte_size bigint not null check (byte_size >= 0),
  account_id uuid,
  contact_id uuid,
  uploaded_by uuid references profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint crm_documents_anchor check (account_id is not null or contact_id is not null),
  constraint crm_documents_account_fk
    foreign key (account_id, owning_organization_id)
    references crm_accounts (id, owning_organization_id) on delete cascade,
  constraint crm_documents_contact_fk
    foreign key (contact_id, owning_organization_id)
    references crm_contacts (id, owning_organization_id) on delete cascade,
  constraint crm_documents_path_prefix check (storage_path like owning_organization_id::text || '/%')
);

comment on table crm_documents is 'Documents stored against accounts/contacts in the private crm-documents bucket. storage_path is always prefixed with the owning organisation id (enforced), which the storage policies key on.';

create index crm_documents_account_idx on crm_documents (account_id) where account_id is not null;
create index crm_documents_contact_idx on crm_documents (contact_id) where contact_id is not null;

-- ---- RLS ------------------------------------------------------------------

alter table crm_accounts enable row level security;
alter table crm_contacts enable row level security;
alter table crm_account_contacts enable row level security;
alter table crm_activities enable row level security;
alter table crm_documents enable row level security;

create policy crm_accounts_org on crm_accounts
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

create policy crm_contacts_org on crm_contacts
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

create policy crm_account_contacts_org on crm_account_contacts
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

create policy crm_activities_org on crm_activities
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

create policy crm_documents_org on crm_documents
  for all using (crm_org_access(owning_organization_id))
  with check (crm_org_access(owning_organization_id));

grant select, insert, update, delete on crm_accounts to authenticated;
grant select, insert, update, delete on crm_contacts to authenticated;
grant select, insert, update, delete on crm_account_contacts to authenticated;
grant select, insert, update, delete on crm_activities to authenticated;
grant select, insert, update, delete on crm_documents to authenticated;

-- ---- Private storage bucket ----------------------------------------------

insert into storage.buckets (id, name, public)
values ('crm-documents', 'crm-documents', false)
on conflict (id) do nothing;

-- Authenticated users may read objects only under their own org's prefix
-- (and only with CRM access). Writes go through the application layer with
-- the service-role key, so no insert/update/delete policies are granted.
create policy "crm documents org read" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'crm-documents'
    and case
      when split_part(name, '/', 1) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then crm_org_access(split_part(name, '/', 1)::uuid)
      else false
    end
  );
