-- 028: per-tenant module enablement + per-profile capability grants.
-- APPLIED to Supabase project pqmdtqsscyltykgcwwus on 2026-07-25 as
-- migration `bespokelms_tenant_modules_028` (via the Supabase MCP connector).
--
-- tenant_modules is the platform layer that says which optional modules
-- (sales_crm now; support_desk, marketing, ... later) are switched on for a
-- given organisation. feature_flags stays platform-global; this table is the
-- per-tenant dimension the Operations modules need.
--
-- profile_capabilities grants cross-cutting responsibilities (sales,
-- marketing, ...) to individual profiles, additive to the app_role tier —
-- one person may hold several. Navigation visibility can address these as
-- pseudo-roles ('capability:sales') because nav_item_visibility stores role
-- as text by design.

create table if not exists tenant_modules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  module_key text not null,
  enabled boolean not null default false,
  enabled_at timestamptz,
  enabled_by uuid references profiles(id) on delete set null,
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tenant_modules_org_module_unique unique (organization_id, module_key),
  constraint tenant_modules_key_format check (module_key ~ '^[a-z][a-z0-9_]*$')
);

comment on table tenant_modules is 'Per-tenant enablement of optional platform modules (sales_crm, ...). Row absent or enabled=false means the module is off for that organisation. settings carries per-module configuration (e.g. CRM retention months, default currency).';

create table if not exists profile_capabilities (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  capability text not null,
  granted_by uuid references profiles(id) on delete set null,
  granted_at timestamptz not null default now(),
  constraint profile_capabilities_unique unique (profile_id, capability),
  constraint profile_capabilities_format check (capability ~ '^[a-z][a-z0-9_]*$')
);

comment on table profile_capabilities is 'Cross-cutting responsibilities granted to a profile (sales, marketing, ...), additive to its role tier. A person may hold several capabilities; module access checks combine role tier OR capability.';

create index if not exists tenant_modules_org_idx on tenant_modules (organization_id);
create index if not exists profile_capabilities_profile_idx on profile_capabilities (profile_id);

-- Is a module enabled for exactly this organisation (no subtree traversal —
-- module enablement, like CRM data, is org-exact).
create or replace function module_enabled(org uuid, mod text)
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from tenant_modules
    where organization_id = org and module_key = mod and enabled
  );
$$;

-- Does the calling user hold a capability grant.
create or replace function has_capability(cap text, uid uuid default auth.uid())
returns boolean
language sql stable security definer
set search_path to 'public'
as $$
  select exists (
    select 1
    from profile_capabilities pc
    join profiles p on p.id = pc.profile_id
    where p.auth_user_id = uid and pc.capability = cap
  );
$$;

revoke execute on function module_enabled(uuid, text) from public, anon;
revoke execute on function has_capability(text, uuid) from public, anon;
grant execute on function module_enabled(uuid, text) to authenticated;
grant execute on function has_capability(text, uuid) to authenticated;

alter table tenant_modules enable row level security;
alter table profile_capabilities enable row level security;

-- Platform owner manages module enablement across the estate.
create policy tenant_modules_owner_all on tenant_modules
  for all using (is_platform_owner()) with check (is_platform_owner());

-- Tenant admins can read their own organisation's module rows (never write).
create policy tenant_modules_org_read on tenant_modules
  for select using (organization_id = auth_org_id() and is_admin());

-- Capabilities: owner manages all; org admins manage grants inside their own
-- organisation only; every user can read their own grants.
create policy profile_capabilities_owner_all on profile_capabilities
  for all using (is_platform_owner()) with check (is_platform_owner());

create policy profile_capabilities_self_read on profile_capabilities
  for select using (profile_id = my_profile_id());

create policy profile_capabilities_org_admin on profile_capabilities
  for all using (
    is_admin() and exists (
      select 1 from profiles p
      where p.id = profile_capabilities.profile_id
        and p.organization_id = auth_org_id()
    )
  ) with check (
    is_admin() and exists (
      select 1 from profiles p
      where p.id = profile_capabilities.profile_id
        and p.organization_id = auth_org_id()
    )
  );

grant select, insert, update, delete on tenant_modules to authenticated;
grant select, insert, update, delete on profile_capabilities to authenticated;

-- Seed: Sales CRM on for the BespokeLMS platform organisation only.
insert into tenant_modules (organization_id, module_key, enabled, enabled_at, settings)
select o.id, 'sales_crm', true, now(),
       jsonb_build_object('crm_retention_months', 36, 'default_currency', 'GBP')
from organizations o
where o.type = 'platform'
on conflict (organization_id, module_key) do nothing;

-- Seed: the platform owner's profile holds the sales + marketing capabilities
-- (representative dual-responsibility grant; capabilities are per-person data).
insert into profile_capabilities (profile_id, capability)
select p.id, c.cap
from profiles p
cross join (values ('sales'), ('marketing')) as c(cap)
where p.role = 'bespokelms_owner'
on conflict (profile_id, capability) do nothing;
