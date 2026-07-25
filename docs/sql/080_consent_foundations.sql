-- 080: consent foundations (CMP phase C1). APPLIED to pqmdtqsscyltykgcwwus.
--
-- Sites, the domains they run on, the purposes a visitor is asked about and
-- the vendors behind each purpose. No banner and no ledger yet — those are
-- 081 and 082.
--
-- Numbering: Website & Consent owns 060–079 for the CMS and 080–099 for
-- consent. The build spec provisionally said 050–056; that block belongs to
-- the parallel CRM workstream, so the family moved.
--
-- ONE RULE SHAPES ALL OF THIS: the tenant is the data controller of its own
-- consent records; we are their processor. So unlike every other table in the
-- platform, is_platform_owner() is NOT a skeleton key here. The platform owner
-- reads BespokeLMS's own consent rows and nobody else's, and the DPA can
-- honestly say so.

create type consent_category as enum ('necessary', 'functional', 'analytics', 'marketing', 'personalisation');
create type consent_ruleset as enum ('uk_pecr', 'gdpr', 'us_optout', 'none');

create table public.consent_sites (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  -- Null for a site we do not host. The CMP is sellable on its own, so it must
  -- work for a tenant whose website is somewhere else entirely.
  web_site_id uuid references public.web_sites(id) on delete set null,
  site_key text not null unique,
  name text not null,
  default_ruleset consent_ruleset not null default 'gdpr',
  default_locale text not null default 'en-GB',
  -- Six months. The ICO's April 2026 position is that a consent and a refusal
  -- should be honoured for the same length of time; asking again sooner after
  -- a "no" than after a "yes" is nagging, and it is the pattern regulators
  -- have started naming.
  lifetime_days integer not null default 180,
  reprompt_on_change boolean not null default true,
  blocking_mode text not null default 'auto',
  -- Fail CLOSED: if the config cannot be loaded, nothing non-essential runs.
  -- The alternative silently drops the product's entire promise at exactly
  -- the moment nobody is watching.
  blocking_fail text not null default 'closed',
  consent_mode_enabled boolean not null default true,
  honour_gpc boolean not null default true,
  powered_by boolean not null default true,
  custom_script_host text,
  status text not null default 'draft',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint consent_sites_key_format check (site_key ~ '^bl_[a-z0-9]{24}$'),
  constraint consent_sites_status check (status in ('draft', 'live', 'suspended')),
  constraint consent_sites_blocking_mode check (blocking_mode in ('auto', 'manual', 'off')),
  constraint consent_sites_blocking_fail check (blocking_fail in ('closed', 'open')),
  constraint consent_sites_lifetime check (lifetime_days between 1 and 365)
);

create index consent_sites_org_idx on public.consent_sites (organization_id, created_at desc);

create table public.consent_site_domains (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.consent_sites(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  hostname text not null,
  include_subdomains boolean not null default false,
  verification_token text not null,
  verified_at timestamptz,
  -- When we last saw a request from this origin. The Install screen uses it to
  -- say "we can see your script on 3 of 4 domains" instead of asking the
  -- tenant to take our word for it.
  last_seen_at timestamptz,
  created_at timestamptz not null default now(),
  constraint consent_site_domains_hostname_lower check (hostname = lower(hostname)),
  constraint consent_site_domains_hostname_format check (hostname ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$')
);

create unique index consent_site_domains_hostname_idx on public.consent_site_domains (hostname);
create index consent_site_domains_site_idx on public.consent_site_domains (site_id);

-- Purposes. A row with a null organisation is a PLATFORM DEFAULT that every
-- tenant inherits; a tenant row with the same key overrides it. Same
-- code-declares/data-mirrors shape as the route and block registries.
create table public.consent_purposes (
  id uuid primary key default gen_random_uuid(),
  key text not null,
  organization_id uuid references public.organizations(id) on delete cascade,
  name text not null,
  description text not null,
  category consent_category not null,
  is_required boolean not null default false,
  -- Regions where this purpose is opt-OUT rather than opt-in. UK PECR
  -- Schedule A1 (in force 5 Feb 2026) moved first-party analytics into the
  -- soft opt-out; the rest of the EEA did not follow.
  opt_out_regions text[] not null default '{}',
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  constraint consent_purposes_key_format check (key ~ '^[a-z][a-z0-9_]{1,30}$')
);

create unique index consent_purposes_platform_key_idx
  on public.consent_purposes (key) where organization_id is null;
create unique index consent_purposes_tenant_key_idx
  on public.consent_purposes (organization_id, key) where organization_id is not null;

create table public.consent_vendors (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  site_id uuid references public.consent_sites(id) on delete cascade,
  name text not null,
  purpose_key text not null,
  privacy_url text,
  description text,
  -- HOSTS, not script filenames. Blocking on a file path is the bug we are
  -- not inheriting: a vendor renames or fingerprints a bundle and the rule
  -- stops matching, silently, with no error anywhere.
  hosts text[] not null default '{}',
  cookie_patterns text[] not null default '{}',
  is_third_party boolean not null default true,
  status text not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint consent_vendors_status check (status in ('active', 'retired'))
);

create index consent_vendors_org_idx on public.consent_vendors (organization_id);
create index consent_vendors_site_idx on public.consent_vendors (site_id);

alter table public.consent_sites enable row level security;
alter table public.consent_site_domains enable row level security;
alter table public.consent_purposes enable row level security;
alter table public.consent_vendors enable row level security;

-- ORG-EXACT, with no platform-owner bypass. See the note at the top: we are
-- the tenant's processor here, not their landlord.
create policy consent_sites_rw on public.consent_sites
  for all using (organization_id = auth_org_id()) with check (organization_id = auth_org_id());

create policy consent_site_domains_rw on public.consent_site_domains
  for all using (organization_id = auth_org_id()) with check (organization_id = auth_org_id());

create policy consent_vendors_rw on public.consent_vendors
  for all using (organization_id = auth_org_id()) with check (organization_id = auth_org_id());

-- Purposes are the exception, in one direction only: every tenant may READ the
-- platform defaults, because they are the menu everyone starts from. Writing a
-- platform default stays with the platform owner.
create policy consent_purposes_select on public.consent_purposes
  for select using (organization_id is null or organization_id = auth_org_id());

create policy consent_purposes_tenant_write on public.consent_purposes
  for all using (organization_id is not null and organization_id = auth_org_id())
  with check (organization_id is not null and organization_id = auth_org_id());

create policy consent_purposes_platform_write on public.consent_purposes
  for all using (organization_id is null and is_platform_owner())
  with check (organization_id is null and is_platform_owner());


-- 080b: the five platform-default purposes every tenant inherits.
--
-- Not seed data in the "delete this later" sense: these are the categories the
-- regulators and the market both recognise, and a tenant who never opens the
-- purposes screen still gets a defensible banner. A tenant row with the same
-- key overrides any of them.
insert into public.consent_purposes (key, organization_id, name, description, category, is_required, opt_out_regions, sort_order)
values
  ('necessary', null, 'Strictly necessary',
   'Needed for the site to work: signing in, security, remembering what is in a form. These cannot be switched off.',
   'necessary', true, '{}', 10),

  ('functional', null, 'Functional',
   'Remembers choices you make, such as your language or region, and enables features like embedded video and live chat.',
   'functional', false, '{}', 20),

  ('analytics', null, 'Analytics',
   'Helps us understand how the site is used, so we can improve it. We only ever look at this in aggregate.',
   'analytics', false, '{GB}', 30),

  ('marketing', null, 'Marketing',
   'Used to measure the effectiveness of our advertising and to show you relevant advertising on other sites.',
   'marketing', false, '{}', 40),

  ('personalisation', null, 'Personalisation',
   'Tailors what you see, such as recommended courses, based on how you have used the site before.',
   'personalisation', false, '{}', 50)
on conflict do nothing;
