-- 081: the banner, versioned and hashed (CMP phase C2).
-- APPLIED to pqmdtqsscyltykgcwwus.
--
-- A banner config is published the same way a page is: draft, publish, and the
-- previous version stays behind. The difference is that a published version is
-- also EVIDENCE. If a visitor's choice is ever questioned, the answer has to be
-- "here is the exact interface they were shown", not "here is the banner as it
-- is configured today" -- so publishing freezes the whole document and stores
-- its hash, and every consent record carries that hash forward.

create table public.consent_banner_configs (
  id uuid primary key default gen_random_uuid(),
  site_id uuid not null references public.consent_sites(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  version_no integer not null,
  state version_status not null default 'draft',
  layout text not null default 'dialog',
  position text not null default 'centre',
  show_overlay boolean not null default true,
  -- TOKEN KEYS ONLY, validated on save. Same rule as the page blocks: a
  -- banner cannot introduce a colour the design system does not have, which
  -- is also what keeps it recognisably the tenant's brand.
  style jsonb not null default '{}'::jsonb,
  copy jsonb not null default '{}'::jsonb,
  purposes text[] not null default '{}',
  geo_rules jsonb not null default '{}'::jsonb,
  -- The exact document served to browsers, frozen at publish.
  config_json jsonb,
  config_hash text,
  screenshot_path text,
  published_by uuid references public.profiles(id) on delete set null,
  published_at timestamptz,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint consent_banner_layout check (layout in ('dialog', 'bar', 'corner')),
  constraint consent_banner_position check (position in ('centre', 'top', 'bottom', 'bottom-left', 'bottom-right')),
  -- A published version without its frozen document and hash would be a
  -- record of nothing.
  constraint consent_banner_published_is_evidence check (
    state <> 'published' or (config_json is not null and config_hash is not null and published_at is not null)
  ),
  unique (site_id, version_no)
);

create index consent_banner_configs_site_idx on public.consent_banner_configs (site_id, version_no desc);
create unique index consent_banner_live_idx on public.consent_banner_configs (site_id) where state = 'published';

-- Banner copy, per locale. Rows with a null organisation are the platform's
-- translated template strings; a tenant row overrides one.
create table public.consent_i18n_strings (
  id uuid primary key default gen_random_uuid(),
  locale text not null,
  key text not null,
  organization_id uuid references public.organizations(id) on delete cascade,
  value text not null,
  -- Where the wording came from. A machine translation of a legal notice and
  -- a reviewed one are not the same thing, and the difference has to survive
  -- in the record rather than in somebody's memory.
  source text not null default 'platform',
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint consent_i18n_source check (source in ('platform', 'tenant', 'ai', 'professional')),
  constraint consent_i18n_locale_format check (locale ~ '^[a-z]{2}(-[A-Z]{2})?$')
);

create unique index consent_i18n_platform_idx
  on public.consent_i18n_strings (locale, key) where organization_id is null;
create unique index consent_i18n_tenant_idx
  on public.consent_i18n_strings (organization_id, locale, key) where organization_id is not null;

alter table public.consent_banner_configs enable row level security;
alter table public.consent_i18n_strings enable row level security;

create policy consent_banner_configs_rw on public.consent_banner_configs
  for all using (organization_id = auth_org_id()) with check (organization_id = auth_org_id());

create policy consent_i18n_select on public.consent_i18n_strings
  for select using (organization_id is null or organization_id = auth_org_id());

create policy consent_i18n_tenant_write on public.consent_i18n_strings
  for all using (organization_id is not null and organization_id = auth_org_id())
  with check (organization_id is not null and organization_id = auth_org_id());

create policy consent_i18n_platform_write on public.consent_i18n_strings
  for all using (organization_id is null and is_platform_owner())
  with check (organization_id is null and is_platform_owner());
