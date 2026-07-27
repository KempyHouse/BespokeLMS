-- 089: the email-gated demo. APPLIED to pqmdtqsscyltykgcwwus.
--
-- Nobody sees the inside of the platform without leaving an email address,
-- and what they then see is a DEMO TENANT: a real organisation flagged
-- is_demo, whose members hold the new 'demo' role. The shared global course
-- catalogue is already visible to any organisation, so the demo tenant has
-- real courses to show without a single row of invented content.
--
-- The gate is a magic link. Sending the link to the address IS the
-- verification - a made-up address never receives it. Tokens are stored as
-- SHA-256 hashes (a leaked table must not be a bag of live links), expire in
-- 48 hours, and redeem exactly once. Redemption creates a per-visitor
-- profile in the demo organisation and mints an ordinary session with the
-- 'demo' role; EnsureDemoIsReadOnly then refuses every configuration write
-- by METHOD, so a settings screen that does not exist yet is already covered.
--
-- demo_requests has RLS enabled and NO policies: the service role is the
-- only thing that can touch it. It is lead capture and auth machinery, not
-- tenant data.

alter type app_role add value if not exists 'demo';

alter table public.organizations
  add column if not exists is_demo boolean not null default false;

-- The demo tenant is shaped as a reseller because that is the story the demo
-- tells: a company selling training under its own brand.
insert into public.organizations (name, slug, type, operator_subtype, is_demo)
select 'BespokeLMS Demo', 'demo', 'operator', 'reseller', true
where not exists (select 1 from public.organizations where slug = 'demo');

create table if not exists public.demo_requests (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  token_hash text not null unique,
  status text not null default 'pending' check (status in ('pending', 'redeemed', 'expired')),
  profile_id uuid references public.profiles(id) on delete set null,
  marketing_consent boolean not null default false,
  consent_statement text,
  ip_hash text,
  user_agent_family text,
  expires_at timestamptz not null,
  redeemed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists demo_requests_email on public.demo_requests (email, created_at desc);

alter table public.demo_requests enable row level security;
