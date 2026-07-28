-- Local validation shim: the subset of migrations 001-040 that 041/042/043/052
-- depend on. NOT part of the migration series — never applied to Supabase.

create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

do $$ begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon; end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated; end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role; end if;
end $$;

grant usage on schema public to anon, authenticated, service_role;

create schema if not exists auth;
create or replace function auth.uid() returns uuid
language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;

create type org_type as enum ('platform', 'operator', 'client');
create type operator_subtype as enum ('reseller', 'inhouse', 'own_brand');
create type app_role as enum ('bespokelms_owner', 'lms_operator_admin', 'client_admin', 'team_manager', 'learner');
create type employment_status as enum ('active', 'inactive', 'never');
create type theme_pref as enum ('light', 'dark', 'system');
create type crm_activity_type as enum ('note','call','email','meeting','task','sms','whatsapp','document','system');
create type crm_activity_direction as enum ('inbound','outbound','internal');
create type crm_lifecycle_stage as enum ('lead','marketing_qualified','sales_qualified','opportunity','customer','churned','partner');
create type crm_record_source as enum ('manual','import_freshsales','import_csv','web_form','auto_link','api','sync');

create table organizations (
    id uuid primary key default gen_random_uuid(),
    parent_id uuid references organizations (id),
    type org_type not null,
    operator_subtype operator_subtype,
    has_client_layer boolean not null default false,
    subtype text,
    name text not null,
    slug text not null unique,
    location text,
    brand_theme jsonb,
    created_at timestamptz not null default now(),
    currency char(3) not null default 'GBP'
);

create table teams (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references organizations (id),
    name text not null
);

create table profiles (
    id uuid primary key default gen_random_uuid(),
    auth_user_id uuid,
    organization_id uuid not null references organizations (id),
    team_id uuid references teams (id),
    role app_role not null,
    email text,
    job_title text,
    employment_status employment_status not null default 'active',
    theme_preference theme_pref not null default 'system',
    created_at timestamptz not null default now(),
    first_name text, last_name text, full_name text,
    preferred_language text
);

create table tenant_modules (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references organizations (id) on delete cascade,
    module_key text not null,
    enabled boolean not null default false,
    enabled_at timestamptz,
    enabled_by uuid references profiles (id),
    settings jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (organization_id, module_key)
);

create table profile_capabilities (
    id uuid primary key default gen_random_uuid(),
    profile_id uuid not null references profiles (id) on delete cascade,
    capability text not null,
    granted_by uuid references profiles (id),
    granted_at timestamptz not null default now(),
    unique (profile_id, capability)
);

create table tags (
    id uuid primary key default gen_random_uuid(),
    key text not null,
    label text not null,
    unique (key)
);

create table crm_accounts (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references organizations (id) on delete cascade,
    organization_id uuid references organizations (id),
    name text not null,
    lifecycle_stage crm_lifecycle_stage not null default 'lead',
    archived_at timestamptz,
    created_at timestamptz not null default now(),
    unique (id, owning_organization_id)
);

create table crm_contacts (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references organizations (id) on delete cascade,
    first_name text, last_name text,
    email text,
    profile_id uuid references profiles (id),
    lifecycle_stage crm_lifecycle_stage not null default 'lead',
    source crm_record_source not null default 'manual',
    archived_at timestamptz,
    created_at timestamptz not null default now(),
    unique (id, owning_organization_id)
);

create table crm_deals (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references organizations (id) on delete cascade,
    name text not null,
    unique (id, owning_organization_id)
);

create table crm_activities (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references organizations (id) on delete cascade,
    activity_type crm_activity_type not null,
    direction crm_activity_direction,
    subject text,
    body text,
    happened_at timestamptz not null default now(),
    due_at timestamptz, completed_at timestamptz,
    actor_profile_id uuid references profiles (id),
    account_id uuid references crm_accounts (id) on delete cascade,
    contact_id uuid references crm_contacts (id) on delete cascade,
    deal_id uuid references crm_deals (id) on delete cascade,
    channel_refs jsonb not null default '{}'::jsonb,
    source crm_record_source not null default 'manual',
    created_by uuid references profiles (id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint crm_activities_anchor check (
        account_id is not null or contact_id is not null or deal_id is not null
    )
);

create table audit_log (
    id uuid primary key default gen_random_uuid(),
    action text not null,
    actor_id uuid,
    organization_id uuid,
    entity text, entity_id uuid,
    meta jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now()
);

-- Helper functions, copied verbatim from the live database.
create or replace function auth_org_id() returns uuid
language sql stable security definer set search_path to 'public' as $$
  select organization_id from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function auth_role() returns app_role
language sql stable security definer set search_path to 'public' as $$
  select role from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function my_profile_id() returns uuid
language sql stable security definer set search_path to 'public' as $$
  select id from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function is_admin(uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from profiles where auth_user_id = uid
    and role in ('bespokelms_owner','lms_operator_admin','client_admin'));
$$;

create or replace function is_platform_owner(uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from profiles where auth_user_id = uid and role = 'bespokelms_owner');
$$;

create or replace function has_capability(cap text, uid uuid default auth.uid()) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from profile_capabilities pc join profiles p on p.id = pc.profile_id
    where p.auth_user_id = uid and pc.capability = cap);
$$;

create or replace function module_enabled(org uuid, mod text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists (select 1 from tenant_modules where organization_id = org and module_key = mod and enabled);
$$;

create or replace function org_and_descendants(root uuid) returns setof uuid
language sql stable security definer set search_path to 'public' as $$
  with recursive tree as (
    select id from organizations where id = root
    union all
    select o.id from organizations o join tree t on o.parent_id = t.id
  ) select id from tree;
$$;

grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to anon, authenticated;

-- Fixture data mirroring the live tenant tree.
insert into organizations (id, parent_id, type, operator_subtype, name, slug) values
  ('f8bd0282-7e62-4f03-9f63-199a9f7dc35c', null, 'platform', null, 'BespokeLMS', 'bespokelms'),
  ('88c98875-7f24-4534-a329-f7930b58cebe', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'operator', 'reseller', 'Turner Price', 'tp'),
  ('b1d7e5a2-b19b-4bd2-a160-944933794bd5', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'operator', 'own_brand', 'TeachHQ', 'teachhq'),
  ('aaaaaaaa-0000-4000-8000-000000000001', '88c98875-7f24-4534-a329-f7930b58cebe', 'client', null, 'All Saints Primary', 'all-saints');

insert into profiles (id, auth_user_id, organization_id, role, email, full_name) values
  ('06313023-2de7-455f-8b05-1a4bf88a03eb', '00000000-0000-4000-8000-000000000001', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'bespokelms_owner', 'owner@bespokelms.test', 'Andrew Kemp'),
  ('1caa7e4d-ab84-4cee-9ab4-779a18ab3748', '00000000-0000-4000-8000-000000000002', '88c98875-7f24-4534-a329-f7930b58cebe', 'lms_operator_admin', 'admin@tp.test', 'Turner Price Admin'),
  ('bbbbbbbb-0000-4000-8000-000000000003', '00000000-0000-4000-8000-000000000003', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'team_manager', 'agent@bespokelms.test', 'Platform Agent'),
  ('cccccccc-0000-4000-8000-000000000004', '00000000-0000-4000-8000-000000000004', '88c98875-7f24-4534-a329-f7930b58cebe', 'team_manager', 'tpagent@tp.test', 'TP Agent'),
  ('dddddddd-0000-4000-8000-000000000005', '00000000-0000-4000-8000-000000000005', 'aaaaaaaa-0000-4000-8000-000000000001', 'learner', 'emma@allsaints.test', 'Emma Wilkinson'),
  ('eeeeeeee-0000-4000-8000-000000000006', '00000000-0000-4000-8000-000000000006', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'team_manager', 'sales@bespokelms.test', 'Platform Sales');

insert into profile_capabilities (profile_id, capability) values
  ('bbbbbbbb-0000-4000-8000-000000000003', 'support'),
  ('cccccccc-0000-4000-8000-000000000004', 'support'),
  ('eeeeeeee-0000-4000-8000-000000000006', 'sales');

insert into crm_accounts (id, owning_organization_id, name) values
  ('11111111-0000-4000-8000-000000000001', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'Turner Price Limited');

insert into crm_contacts (id, owning_organization_id, first_name, last_name, email, profile_id) values
  ('22222222-0000-4000-8000-000000000001', 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'Turner', 'Admin', 'admin@tp.test', '1caa7e4d-ab84-4cee-9ab4-779a18ab3748');
