-- ===========================================================================
-- BespokeLMS — Schema migration 001 (multi-tenant white-label LMS)
-- Target: Supabase / Postgres. All data is mock/demo (prototype).
-- Safe to run once on a fresh project. Seed data ships separately (002_seed.sql).
--
-- Security model: Supabase Auth is the identity provider. Each user has a
-- profiles row linked via profiles.auth_user_id = auth.users.id. Row-Level
-- Security cascades down the organizations tree (an org + all descendants).
-- Secret columns (e.g. ai_integrations.api_key_cipher) are encrypted by the
-- Laravel server and never read client-side (server/service-role only).
-- ===========================================================================

create extension if not exists pgcrypto;

-- ============================ ENUMS ========================================
create type org_type              as enum ('platform','operator','client');
create type operator_subtype      as enum ('reseller','inhouse','own_brand');
create type app_role              as enum ('bespokelms_owner','lms_operator_admin','client_admin','team_manager','learner');
create type employment_status     as enum ('active','inactive','never');
create type theme_pref            as enum ('light','dark','system');
create type enrollment_status     as enum ('assigned','inprogress','completed','overdue','duesoon','notstarted','failed','notassigned');
create type enrollment_source     as enum ('auto','manual','self');
create type course_catalog_status as enum ('published','coming_soon','retired');
create type view_visibility       as enum ('personal','shared_group','shared_org');
create type ai_provider           as enum ('anthropic','openai','azure_openai','custom');
create type ai_status             as enum ('unconfigured','connected','error','disabled');

-- ============================ TENANCY ======================================
create table organizations (
  id                uuid primary key default gen_random_uuid(),
  parent_id         uuid references organizations(id) on delete cascade,
  type              org_type not null,
  operator_subtype  operator_subtype,                 -- only for type='operator'
  has_client_layer  boolean not null default true,    -- false for 'inhouse' operators
  subtype           text,                             -- 'trust'|'school'|'site'|'department' (display parity)
  name              text not null,
  slug              text unique,                      -- tenant routing (tp, teachhq, marchfoods…)
  location          text,
  brand_theme       jsonb not null default '{}'::jsonb, -- per-operator white-label (logo, accent…)
  created_at        timestamptz not null default now(),
  constraint operator_subtype_matches_type
    check ( (type = 'operator') = (operator_subtype is not null) )
);
create index on organizations(parent_id);
create index on organizations(type);

create table teams (
  id               uuid primary key default gen_random_uuid(),
  organization_id  uuid not null references organizations(id) on delete cascade,
  name             text not null,
  created_at       timestamptz not null default now()
);
create index on teams(organization_id);

create table profiles (
  id                 uuid primary key default gen_random_uuid(),
  auth_user_id       uuid unique,                     -- = auth.users.id once Supabase Auth is wired
  organization_id    uuid not null references organizations(id) on delete cascade,
  team_id            uuid references teams(id) on delete set null,
  role               app_role not null,
  full_name          text not null,
  email              text not null,
  job_title          text,
  avatar_seed        text,
  employment_status  employment_status not null default 'active',
  theme_preference   theme_pref not null default 'system',
  last_active_at     timestamptz,
  created_at         timestamptz not null default now()
);
create index on profiles(organization_id);
create index on profiles(team_id);
create index on profiles(auth_user_id);
create index on profiles(role);

-- ===================== RBAC HELPER FUNCTIONS ===============================
-- All SECURITY DEFINER so RLS policies can call them without recursing into
-- the very tables the policy protects.

create or replace function org_and_descendants(root uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  with recursive tree as (
    select id from organizations where id = root
    union all
    select o.id from organizations o join tree t on o.parent_id = t.id
  ) select id from tree;
$$;

create or replace function my_profile_id()
returns uuid language sql stable security definer set search_path = public as $$
  select id from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function my_team_id()
returns uuid language sql stable security definer set search_path = public as $$
  select team_id from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function auth_org_id()
returns uuid language sql stable security definer set search_path = public as $$
  select organization_id from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function auth_role()
returns app_role language sql stable security definer set search_path = public as $$
  select role from profiles where auth_user_id = auth.uid() limit 1;
$$;

create or replace function is_admin(uid uuid default auth.uid())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where auth_user_id = uid
      and role in ('bespokelms_owner','lms_operator_admin','client_admin')
  );
$$;

-- the set of profile ids the caller is allowed to see (self / team / org subtree)
create or replace function visible_profile_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from profiles p
  where p.id = my_profile_id()
     or (auth_role() = 'team_manager' and p.team_id = my_team_id())
     or (auth_role() in ('client_admin','lms_operator_admin','bespokelms_owner')
         and p.organization_id in (select org_and_descendants(auth_org_id())));
$$;

-- ======================= LEARNING CONTENT ==================================
create table course_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  color_bg   text,
  color_text text,
  sort       int not null default 0
);

create table courses (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  category_id     uuid references course_categories(id),
  level           text,
  duration_min    int,
  price_pennies   int,                              -- £ price in pennies (mock)
  credits         int,
  accreditation   text,
  description     text,
  thumbnail_path  text,
  is_recurring    boolean not null default false,
  catalog_status  course_catalog_status not null default 'published',
  owner_org_id    uuid references organizations(id),-- null = platform catalogue
  created_at      timestamptz not null default now()
);
create index on courses(category_id);
create index on courses(catalog_status);

create table enrollments (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references profiles(id) on delete cascade,
  course_id     uuid not null references courses(id) on delete cascade,
  status        enrollment_status not null default 'notstarted',
  progress_pct  int not null default 0 check (progress_pct between 0 and 100),
  assigned_at   timestamptz,
  due_at        timestamptz,
  completed_at  timestamptz,
  source        enrollment_source not null default 'manual',
  created_at    timestamptz not null default now(),
  unique (user_id, course_id)
);
create index on enrollments(user_id);
create index on enrollments(course_id);
create index on enrollments(status);

create table certificates (
  id            uuid primary key default gen_random_uuid(),
  enrollment_id uuid references enrollments(id) on delete cascade,
  user_id       uuid not null references profiles(id) on delete cascade,
  course_id     uuid not null references courses(id) on delete cascade,
  issued_at     timestamptz not null default now(),
  expires_at    timestamptz,
  file_path     text
);

create table course_requirements (
  id           uuid primary key default gen_random_uuid(),
  scope        text not null,          -- 'role' | 'team' | 'org'
  scope_ref    text not null,          -- role name / team id / org id
  course_id    uuid not null references courses(id) on delete cascade,
  is_mandatory boolean not null default true
);

-- ========================== ENGAGEMENT =====================================
create table saved_views (
  id              uuid primary key default gen_random_uuid(),
  owner_id        uuid not null references profiles(id) on delete cascade,
  organization_id uuid not null references organizations(id) on delete cascade,
  name            text not null,
  description     text,
  icon            text,
  visibility      view_visibility not null default 'personal',
  is_default      boolean not null default false,
  sort_order      int not null default 0,
  state           jsonb not null default '{}'::jsonb,   -- scope/view/sort/filters
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on saved_views(owner_id);
create index on saved_views(organization_id);

create table notifications (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  type       text,
  title      text not null,
  body       text,
  link       text,
  is_read    boolean not null default false,
  created_at timestamptz not null default now()
);
create index on notifications(user_id, is_read);

create table ideas (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,
  title           text not null,
  description     text,
  status          text not null default 'idea',   -- idea|planned|in_progress|released
  votes           int not null default 0,
  created_at      timestamptz not null default now()
);

create table idea_votes (
  idea_id    uuid not null references ideas(id) on delete cascade,
  user_id    uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (idea_id, user_id)
);

create table chat_messages (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references profiles(id) on delete cascade,
  session_id uuid not null default gen_random_uuid(),
  sender     text not null,                        -- 'user' | 'bot'
  body       text not null,
  created_at timestamptz not null default now()
);
create index on chat_messages(user_id, session_id);

-- ======================= ADMIN / PLATFORM ==================================
create table platform_settings (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform-wide
  key             text not null,
  value           jsonb not null default '{}'::jsonb,
  updated_by      uuid references profiles(id),
  updated_at      timestamptz not null default now(),
  unique (organization_id, key)
);

create table ai_integrations (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform-wide
  provider        ai_provider not null,
  display_name    text not null,
  is_enabled      boolean not null default false,
  api_key_cipher  text,                         -- encrypted at rest; NEVER returned to the browser
  default_model   text,
  base_url        text,
  options         jsonb not null default '{}'::jsonb,
  status          ai_status not null default 'unconfigured',
  last_tested_at  timestamptz,
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on ai_integrations(organization_id);

create table ai_usage_logs (
  id              uuid primary key default gen_random_uuid(),
  integration_id  uuid references ai_integrations(id) on delete set null,
  organization_id uuid references organizations(id) on delete cascade,
  feature         text,
  tokens_in       int,
  tokens_out      int,
  created_at      timestamptz not null default now()
);

create table audit_log (
  id              uuid primary key default gen_random_uuid(),
  actor_id        uuid references profiles(id) on delete set null,
  organization_id uuid references organizations(id) on delete cascade,
  action          text not null,
  entity          text,
  entity_id       uuid,
  meta            jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);

-- ======================= COMPLIANCE VIEWS ==================================
create or replace view v_user_compliance as
select
  p.id as user_id, p.organization_id, p.team_id,
  count(e.id) filter (where e.status <> 'notassigned')                       as assigned_count,
  count(e.id) filter (where e.status = 'completed')                          as completed_count,
  count(e.id) filter (where e.status = 'overdue')                            as overdue_count,
  case when count(e.id) filter (where e.status <> 'notassigned') = 0 then 100
       else round(100.0 * count(e.id) filter (where e.status = 'completed')
                        / count(e.id) filter (where e.status <> 'notassigned'))
  end as compliance_pct
from profiles p
left join enrollments e on e.user_id = p.id
group by p.id, p.organization_id, p.team_id;

create or replace view v_team_compliance as
select p.organization_id, p.team_id,
  count(distinct p.id)               as learners,
  round(avg(uc.compliance_pct))      as compliance_pct,
  sum(uc.overdue_count)              as overdue_count
from profiles p
join v_user_compliance uc on uc.user_id = p.id
where p.team_id is not null
group by p.organization_id, p.team_id;

create or replace view v_org_compliance as
select o.id as organization_id, o.name, o.type, o.operator_subtype,
  count(distinct p.id)                          as learners,
  coalesce(round(avg(uc.compliance_pct)),100)   as compliance_pct,
  coalesce(sum(uc.overdue_count),0)             as overdue_count
from organizations o
left join profiles p on p.organization_id = o.id
left join v_user_compliance uc on uc.user_id = p.id
group by o.id, o.name, o.type, o.operator_subtype;

-- ========================= ROW-LEVEL SECURITY ==============================
alter table organizations      enable row level security;
alter table teams              enable row level security;
alter table profiles           enable row level security;
alter table course_categories  enable row level security;
alter table courses            enable row level security;
alter table enrollments        enable row level security;
alter table certificates       enable row level security;
alter table course_requirements enable row level security;
alter table saved_views        enable row level security;
alter table notifications      enable row level security;
alter table ideas              enable row level security;
alter table idea_votes         enable row level security;
alter table chat_messages      enable row level security;
alter table platform_settings  enable row level security;
alter table ai_integrations    enable row level security;
alter table ai_usage_logs      enable row level security;
alter table audit_log          enable row level security;

-- tenancy: visible within the caller's org subtree
create policy org_read   on organizations for select using ( id in (select org_and_descendants(auth_org_id())) );
create policy teams_read on teams         for select using ( organization_id in (select org_and_descendants(auth_org_id())) );

-- people: self / team (managers) / org subtree (admins)
create policy profiles_read on profiles for select using ( id in (select visible_profile_ids()) );

-- catalogue: any authenticated tenant member may browse
create policy cats_read    on course_categories for select using ( auth.uid() is not null );
create policy courses_read on courses          for select using ( auth.uid() is not null );

-- learner records: own / visible-people set
create policy enrollments_read  on enrollments  for select using ( user_id in (select visible_profile_ids()) );
create policy certificates_read on certificates for select using ( user_id in (select visible_profile_ids()) );
create policy requirements_read on course_requirements for select using ( auth.uid() is not null );

-- saved views: owner (any op) + shared-in-subtree (read)
create policy views_owner on saved_views for all
  using ( owner_id = my_profile_id() ) with check ( owner_id = my_profile_id() );
create policy views_shared_read on saved_views for select
  using ( visibility <> 'personal' and organization_id in (select org_and_descendants(auth_org_id())) );

-- strictly personal
create policy notif_own on notifications  for all using ( user_id = my_profile_id() ) with check ( user_id = my_profile_id() );
create policy chat_own  on chat_messages  for all using ( user_id = my_profile_id() ) with check ( user_id = my_profile_id() );

-- ideas: read within subtree, vote as self
create policy ideas_read on ideas for select using ( organization_id is null or organization_id in (select org_and_descendants(auth_org_id())) );
create policy votes_own  on idea_votes for all using ( user_id = my_profile_id() ) with check ( user_id = my_profile_id() );

-- admin-only surfaces (org-scoped)
create policy settings_admin on platform_settings for all
  using ( is_admin() and (organization_id is null or organization_id in (select org_and_descendants(auth_org_id()))) )
  with check ( is_admin() );
create policy ai_admin on ai_integrations for all
  using ( is_admin() and (organization_id is null or organization_id in (select org_and_descendants(auth_org_id()))) )
  with check ( is_admin() );
create policy usage_admin on ai_usage_logs for select
  using ( is_admin() and (organization_id is null or organization_id in (select org_and_descendants(auth_org_id()))) );
create policy audit_admin on audit_log for select
  using ( is_admin() and (organization_id is null or organization_id in (select org_and_descendants(auth_org_id()))) );

-- ============================ GRANTS =======================================
grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant insert, update, delete on
  saved_views, notifications, chat_messages, idea_votes, ai_integrations,
  platform_settings, enrollments, ideas, audit_log
  to authenticated;
grant execute on all functions in schema public to anon, authenticated;

-- NOTE: server-side (service role) bypasses RLS for seeding and for privileged
-- Laravel operations (e.g. decrypting ai_integrations.api_key_cipher). The anon/
-- publishable key can never read secret columns because those code paths run
-- exclusively on the server.
