-- 065: web forms, and the path from an enquiry to the Sales CRM.
-- APPLIED to pqmdtqsscyltykgcwwus.
--
-- Three tables, and the order matters. A submission is RECORDED FIRST and
-- pushed to the CRM afterwards, so a CRM outage loses nothing: the enquiry is
-- already durable and can be replayed. The opposite arrangement — create the
-- contact, then store the submission — loses the enquiry exactly when the
-- system is already unhappy.
--
-- crm_record_source already carried a 'web_form' value, so this uses the seam
-- the CRM schema anticipated rather than inventing one.

create type web_form_field_type as enum (
  'text', 'email', 'tel', 'textarea', 'select', 'checkbox', 'number'
);

create type web_form_status as enum ('draft', 'live', 'closed');

create type web_form_submission_state as enum ('new', 'linked', 'failed', 'spam');

create table if not exists public.web_forms (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.web_sites(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  key text not null,
  name text not null,
  description text,
  submit_label text not null default 'Send',
  success_message text not null default 'Thank you. We will be in touch.',
  redirect_path text,
  -- Where the "someone has enquired" email goes. Empty means nobody is
  -- emailed; the submission is still recorded and still reaches the CRM.
  notify_emails text[] not null default '{}',
  crm_enabled boolean not null default true,
  crm_owner_profile_id uuid references public.profiles(id) on delete set null,
  crm_lifecycle_stage crm_lifecycle_stage not null default 'lead',
  -- The exact wording the visitor agreed to. Stored on the FORM and copied
  -- onto each submission, so a later edit to this text cannot rewrite what
  -- somebody consented to at the time.
  consent_text text,
  status web_form_status not null default 'draft',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint web_forms_key_format check (key ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' and length(key) <= 60),
  constraint web_forms_redirect_format check (redirect_path is null or redirect_path ~ '^/([a-z0-9]+(?:-[a-z0-9]+)*(?:/[a-z0-9]+(?:-[a-z0-9]+)*)*)?$')
);

create unique index if not exists web_forms_site_key_idx on public.web_forms (site_id, key);

create table if not exists public.web_form_fields (
  id uuid primary key default gen_random_uuid(),
  form_id uuid not null references public.web_forms(id) on delete cascade,
  key text not null,
  label text not null,
  type web_form_field_type not null default 'text',
  placeholder text,
  help_text text,
  required boolean not null default false,
  options text[] not null default '{}',
  max_length integer,
  -- Which CRM column this field feeds, if any. Named columns only: an
  -- unmapped field still reaches the CRM inside the activity body, so nothing
  -- is lost, but only these may write a structured field.
  crm_map text,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint web_form_fields_key_format check (key ~ '^[a-z0-9]+(?:_[a-z0-9]+)*$' and length(key) <= 40),
  constraint web_form_fields_crm_map_allowed check (
    crm_map is null or crm_map in (
      'first_name', 'last_name', 'email', 'phone', 'mobile', 'job_title',
      'account_name', 'website_domain', 'message'
    )
  )
);

create unique index if not exists web_form_fields_form_key_idx on public.web_form_fields (form_id, key);
create index if not exists web_form_fields_form_sort_idx on public.web_form_fields (form_id, sort_order);

create table if not exists public.web_form_submissions (
  id uuid primary key default gen_random_uuid(),
  form_id uuid not null references public.web_forms(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  site_id uuid not null references public.web_sites(id) on delete cascade,
  submitted_at timestamptz not null default now(),
  -- Everything the visitor typed, keyed by field key. The authoritative
  -- record: the CRM row is a projection of this, not the other way round.
  payload jsonb not null default '{}'::jsonb,
  email text,
  full_name text,
  page_path text,
  -- A salted hash, never the address. The raw IP is only needed while the
  -- request is in flight, for rate limiting; keeping it afterwards is personal
  -- data we would have to justify holding.
  ip_hash text,
  user_agent text,
  consent_text text,
  consent_given boolean not null default false,
  state web_form_submission_state not null default 'new',
  crm_contact_id uuid references public.crm_contacts(id) on delete set null,
  crm_account_id uuid references public.crm_accounts(id) on delete set null,
  crm_activity_id uuid references public.crm_activities(id) on delete set null,
  crm_error text,
  created_at timestamptz not null default now()
);

create index if not exists web_form_submissions_form_idx on public.web_form_submissions (form_id, submitted_at desc);
create index if not exists web_form_submissions_org_idx on public.web_form_submissions (organization_id, submitted_at desc);
create index if not exists web_form_submissions_state_idx on public.web_form_submissions (state) where state in ('new', 'failed');

alter table public.web_forms enable row level security;
alter table public.web_form_fields enable row level security;
alter table public.web_form_submissions enable row level security;

-- Same shape as web_pages: a tenant reads its own, the platform owner writes.
-- The public surface never uses these policies — it reads and writes with the
-- service-role key, scoped by the host-resolved organisation.
create policy web_forms_select on public.web_forms
  for select using (organization_id = auth_org_id() or is_platform_owner());
create policy web_forms_write on public.web_forms
  for all using (is_platform_owner()) with check (is_platform_owner());

create policy web_form_fields_select on public.web_form_fields
  for select using (exists (
    select 1 from public.web_forms f
    where f.id = form_id and (f.organization_id = auth_org_id() or is_platform_owner())
  ));
create policy web_form_fields_write on public.web_form_fields
  for all using (is_platform_owner()) with check (is_platform_owner());

create policy web_form_submissions_select on public.web_form_submissions
  for select using (organization_id = auth_org_id() or is_platform_owner());
create policy web_form_submissions_write on public.web_form_submissions
  for all using (is_platform_owner()) with check (is_platform_owner());
