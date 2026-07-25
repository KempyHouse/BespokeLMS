-- ===========================================================================
-- BespokeLMS — Schema migration 008 (Email delivery integration)
-- Target: Supabase / Postgres.  Depends on 001 (+ owner-tier policies).
--
-- Email delivery is configured the same way as AI Integration:
--   · TRANSPORT is owned by the platform owner — one row per provider with a
--     NULL organization_id (Resend / Postmark / SES / SMTP / custom). The
--     enabled provider is the platform default; swapping providers is just
--     enabling a different row. API secrets are encrypted server-side and are
--     never returned to the browser (mirrors ai_integrations.api_key_cipher).
--   · IDENTITY ("alias") is owned by each tenant — a per-organisation sender
--     identity (from name / from address / reply-to / verified domain) that
--     rides on the shared platform transport. Tenant admins manage their own
--     alias; the platform owner can see every alias.
--   · email_send_logs is the delivery ledger (mirrors ai_usage_logs), read by
--     the owner (all) or a tenant admin (own subtree).
--
-- Additive + declarative. Reuses the existing ai_status enum for connection
-- state (unconfigured / connected / error / disabled) and the RBAC helpers
-- is_platform_owner() / is_admin() / auth_org_id() / org_and_descendants().
-- ===========================================================================

-- ============================ ENUMS ========================================
-- Email transport providers. Guarded so the migration is safe to re-run.
do $$
begin
  if not exists (select 1 from pg_type where typname = 'email_provider') then
    create type email_provider as enum ('resend','postmark','ses','smtp','custom');
  end if;
end$$;

-- ==================== PLATFORM TRANSPORT (owner level) =====================
-- One row per provider, organization_id IS NULL. Mirrors ai_integrations.
create table if not exists email_integrations (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform transport
  provider        email_provider not null,
  display_name    text not null,
  is_enabled      boolean not null default false,                       -- the enabled row = platform default
  api_key_cipher  text,                          -- encrypted at rest; NEVER returned to the browser
  from_address    text,                          -- platform default sender (tenants may override via an alias)
  from_name       text,
  reply_to        text,
  base_url        text,                          -- SMTP host / custom (self-hosted) endpoint
  options         jsonb not null default '{}'::jsonb,  -- sending_domain, region, message_stream_id, smtp_port, smtp_username, ...
  status          ai_status not null default 'unconfigured',
  last_tested_at  timestamptz,
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists email_integrations_org_idx on email_integrations(organization_id);
-- exactly one platform row per provider
create unique index if not exists email_integrations_platform_provider_uidx
  on email_integrations(provider) where organization_id is null;

-- ====================== TENANT ALIASES (identity) =========================
-- A tenant's sender identity, ridden on the platform transport. One per org.
create table if not exists tenant_email_aliases (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  from_name       text,
  from_address    text,
  reply_to        text,
  sending_domain  text,
  is_active       boolean not null default false,   -- use this alias instead of the platform default
  is_verified     boolean not null default false,   -- sending domain verified with the provider
  options         jsonb not null default '{}'::jsonb,
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (organization_id)
);
create index if not exists tenant_email_aliases_org_idx on tenant_email_aliases(organization_id);

-- ========================= DELIVERY LEDGER ================================
-- One row per send/delivery event. Recipient is reduced to its domain so no
-- learner PII is retained in the log. Mirrors ai_usage_logs.
create table if not exists email_send_logs (
  id                  uuid primary key default gen_random_uuid(),
  integration_id      uuid references email_integrations(id) on delete set null,
  organization_id     uuid references organizations(id) on delete cascade,
  feature             text,          -- 'password_reset','notification','certificate',...
  event               text,          -- 'queued','sent','delivered','bounced','complained','failed'
  to_domain           text,          -- recipient domain only (no full address / PII)
  provider_message_id text,
  meta                jsonb not null default '{}'::jsonb,
  created_at          timestamptz not null default now()
);
create index if not exists email_send_logs_org_idx on email_send_logs(organization_id);
create index if not exists email_send_logs_integration_idx on email_send_logs(integration_id);
create index if not exists email_send_logs_created_idx on email_send_logs(created_at);

-- ========================= ROW-LEVEL SECURITY =============================
alter table email_integrations   enable row level security;
alter table tenant_email_aliases enable row level security;
alter table email_send_logs      enable row level security;

-- Platform transport: owner-only, platform rows (mirrors ai_integrations.ai_platform).
drop policy if exists email_platform on email_integrations;
create policy email_platform on email_integrations for all
  using ( organization_id is null and is_platform_owner() )
  with check ( organization_id is null and is_platform_owner() );

-- Tenant aliases: a tenant admin manages its own subtree's alias; owner sees all.
drop policy if exists email_alias_tenant on tenant_email_aliases;
create policy email_alias_tenant on tenant_email_aliases for all
  using (
    is_platform_owner()
    or ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) )
  )
  with check (
    is_platform_owner()
    or ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) )
  );

-- Delivery logs: read for the owner (all) or a tenant admin (own subtree).
drop policy if exists email_logs_admin on email_send_logs;
create policy email_logs_admin on email_send_logs for select
  using (
    (organization_id is null and is_platform_owner())
    or ( organization_id is not null and is_admin()
         and organization_id in (select org_and_descendants(auth_org_id())) )
  );

-- ============================ GRANTS =======================================
grant select on email_integrations, tenant_email_aliases, email_send_logs to anon, authenticated;
grant insert, update, delete on email_integrations, tenant_email_aliases to authenticated;  -- gated by RLS

-- NOTE: privileged Laravel reads/writes run with the service-role key (bypass
-- RLS) so api_key_cipher is only ever decrypted server-side. The policies above
-- are defence-in-depth for the anon/publishable key.

-- ===================== SEED PLATFORM TRANSPORT ROWS =======================
-- One unconfigured row per provider. Resend carries the current dev default
-- sender; enabling a row + adding its key makes it the platform transport.
insert into email_integrations (organization_id, provider, display_name, is_enabled, from_address, from_name, status)
values
  (null, 'resend',   'Resend',                false, 'no-reply@bespokelms.com', 'BespokeLMS', 'unconfigured'),
  (null, 'postmark', 'Postmark',              false, null,                       null,         'unconfigured'),
  (null, 'ses',      'Amazon SES',            false, null,                       null,         'unconfigured'),
  (null, 'smtp',     'SMTP',                  false, null,                       null,         'unconfigured'),
  (null, 'custom',   'Custom / self-hosted',  false, null,                       null,         'unconfigured')
on conflict do nothing;
