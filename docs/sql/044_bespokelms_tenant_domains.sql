-- 044: Tenant domains — the host -> (organisation, surface) map that lets one
-- Laravel application serve the LMS, a tenant's marketing website and its
-- support portal from different hostnames.
--
-- APPLIED to Supabase project pqmdtqsscyltykgcwwus on 2026-07-25 as migrations
-- `bespokelms_tenant_domains_044` and `bespokelms_tenant_domains_seed_044b`.
--
-- Hostname is the ONLY input that decides which tenant a public request
-- belongs to, so the uniqueness constraint below is the isolation boundary for
-- the whole Website module. Read by App\Http\Middleware\ResolveHost before
-- authentication and before routing.

create type domain_surface as enum ('app', 'marketing', 'support', 'consent');

create table tenant_domains (
  id                 uuid primary key default gen_random_uuid(),
  organization_id    uuid not null references organizations(id) on delete cascade,
  hostname           text not null,
  surface            domain_surface not null,
  is_primary         boolean not null default false,
  redirect_to_id     uuid references tenant_domains(id) on delete set null,
  verification_token text not null default encode(gen_random_bytes(16), 'hex'),
  verified_at        timestamptz,
  ssl_status         text not null default 'pending',
  notes              text,
  created_by         uuid references profiles(id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint tenant_domains_hostname_lowercase check (hostname = lower(hostname)),
  constraint tenant_domains_hostname_format check (
    hostname ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  ),
  constraint tenant_domains_ssl_status check (ssl_status in ('pending', 'issued', 'failed', 'not_applicable')),
  constraint tenant_domains_no_self_redirect check (redirect_to_id is null or redirect_to_id <> id)
);

-- The isolation boundary: one hostname can belong to exactly one tenant.
-- (citext is not installed on this project; the lowercase CHECK plus
-- normalisation on write keeps the plain unique index case-safe.)
create unique index tenant_domains_hostname_key on tenant_domains (hostname);
-- At most one canonical host per (organisation, surface).
create unique index tenant_domains_primary_per_surface
  on tenant_domains (organization_id, surface) where is_primary;
create index tenant_domains_org_idx on tenant_domains (organization_id);

alter table tenant_domains enable row level security;

create policy tenant_domains_select on tenant_domains
  for select using (organization_id = auth_org_id() or is_platform_owner());

-- Writes are platform-owner only: a domain row can redirect a tenant's
-- traffic, so this is the most privileged write in the Website module.
create policy tenant_domains_insert on tenant_domains
  for insert with check (is_platform_owner());
create policy tenant_domains_update on tenant_domains
  for update using (is_platform_owner()) with check (is_platform_owner());
create policy tenant_domains_delete on tenant_domains
  for delete using (is_platform_owner());

grant select on tenant_domains to authenticated;
grant insert, update, delete on tenant_domains to authenticated;

-- 044b: seed the BespokeLMS estate's own hosts. All start UNVERIFIED, so the
-- resolver ignores them until DNS is cut over and the console verifies them.
-- support.bespokelms.com is deliberately absent: it still points at Freshdesk.

insert into tenant_domains (organization_id, hostname, surface, is_primary, notes)
select o.id, d.hostname, d.surface::domain_surface, d.is_primary, d.notes
from organizations o, (values
  ('app.bespokelms.com',  'app',       true,  'The LMS application.'),
  ('www.bespokelms.com',  'marketing', true,  'Marketing website (canonical).'),
  ('bespokelms.com',      'marketing', false, 'Apex — redirects to www.')
) as d(hostname, surface, is_primary, notes)
where o.slug = 'bespokelms' and o.type = 'platform';

update tenant_domains
   set redirect_to_id = (select id from tenant_domains w where w.hostname = 'www.bespokelms.com')
 where hostname = 'bespokelms.com';
