-- ===========================================================================
-- BespokeLMS — Schema migration 007 (Course editor fields)
-- Target: Supabase / Postgres.  Depends on 001–006.
--
-- Backs the course editor: catalogue/marketing/commercial fields on `courses`,
-- content/assessment fields on `course_versions`, and new tables for pricing +
-- retake/retry policy (variable by mechanism, owner-configurable), territories,
-- authors, and coming-soon "notify me" requests. Certification validity +
-- auto-reassign and the review date reuse existing structures (003/005).
--
-- Placement principle: sell/price/find → courses; this version's content → course_versions.
-- Additive + declarative. Backfills a pricing row per existing course.
-- Validated on real Postgres 16 against 001–006.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type pricing_type        as enum ('free','one_off','credits','included_in_subscription','pay_as_you_go');
create type assessment_placement as enum ('inline_between_modules','end_of_course','none');
create type retake_after_pass   as enum ('unlimited','none','limited');

-- ============ COURSES: catalogue / marketing / commercial fields ===========
alter table courses
  add column hero_image_path        text,
  add column hero_image_alt         text,
  add column trailer_video_path     text,               -- uploaded to Storage
  add column trailer_url            text,               -- external (Vimeo/YouTube)
  add column cpd_points             numeric,
  add column cpd_body               text,
  add column meta_title             text,
  add column meta_description       text,
  add column meta_keywords          text,
  add column issues_certificate     boolean not null default true,
  add column certificate_validity   interval,           -- null = never expires
  add column auto_reassign_on_expiry boolean not null default false;

-- ============ COURSE_VERSIONS: content / assessment / staged copy =========
-- The descriptive selling copy (description/aims/objectives + mobile-short
-- variants) lives on the VERSION, so a learner/browser never sees an author's
-- in-progress edits: edits happen on a draft version and only surface when it
-- is published (courses.description from 001 remains the base/fallback that the
-- catalogue COALESCEs with the current published version's copy). Hero/trailer/
-- SEO/commercial stay on `courses` as the always-live shop-window.
alter table course_versions
  add column assessment_placement assessment_placement not null default 'end_of_course',
  add column pass_mark_pct        int check (pass_mark_pct between 0 and 100),
  add column description          text,               -- versioned long description (else course.description)
  add column description_short    text,               -- mobile
  add column aims                 text,
  add column aims_short           text,
  add column objectives           text,
  add column objectives_short     text;

-- ===================== PRICING + RETAKE / RETRY POLICY =====================
-- Retry/retake nullability convention:
--   NULL  = inherit the pricing_defaults value for this pricing_type
--   -1    = unlimited
--   N>=0  = an explicit limit
-- so a course can inherit, or override (including override-to-unlimited via -1).
create table pricing_defaults (
  pricing_type            pricing_type primary key,
  assessment_retry_limit  int not null default -1,          -- attempts to PASS (-1 = unlimited)
  retake_after_pass       retake_after_pass not null default 'none',
  retake_limit            int,                              -- used when retake_after_pass='limited'
  access_revoked_on_pass  boolean not null default false,   -- PAYG: course closes once passed
  updated_by              uuid references profiles(id),
  updated_at              timestamptz not null default now()
);

create table course_pricing (
  course_id               uuid primary key references courses(id) on delete cascade,
  pricing_type            pricing_type not null default 'free',
  price_pennies           int,
  currency                text not null default 'GBP',
  credit_cost             int,
  included_in_subscription boolean not null default false,
  -- per-course overrides (NULL = inherit pricing_defaults; see convention above)
  assessment_retry_limit  int,
  retake_after_pass       retake_after_pass,
  retake_limit            int,
  access_revoked_on_pass  boolean,
  updated_by              uuid references profiles(id),
  updated_at              timestamptz not null default now()
);

-- effective (resolved) policy = course override, else the type default.
create or replace view v_course_effective_pricing as
select
  cp.course_id,
  cp.pricing_type,
  cp.price_pennies,
  cp.currency,
  cp.credit_cost,
  cp.included_in_subscription,
  coalesce(cp.assessment_retry_limit, pd.assessment_retry_limit) as assessment_retry_limit,
  coalesce(cp.retake_after_pass,      pd.retake_after_pass)      as retake_after_pass,
  coalesce(cp.retake_limit,           pd.retake_limit)          as retake_limit,
  coalesce(cp.access_revoked_on_pass, pd.access_revoked_on_pass) as access_revoked_on_pass
from course_pricing cp
join pricing_defaults pd on pd.pricing_type = cp.pricing_type;

-- ========================= TERRITORY / JURISDICTION =======================
create table territories (
  id        uuid primary key default gen_random_uuid(),
  parent_id uuid references territories(id) on delete set null,   -- region → country nesting
  code      text not null unique,
  name      text not null,
  sort      int  not null default 0
);
create index on territories(parent_id);

create table course_territories (
  course_id    uuid not null references courses(id) on delete cascade,
  territory_id uuid not null references territories(id) on delete cascade,
  primary key (course_id, territory_id)
);
create index on course_territories(territory_id);

-- =============================== AUTHORS ==================================
-- Internal user (profile) OR an external named SME; at least one must be set.
create table course_authors (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references courses(id) on delete cascade,
  profile_id   uuid references profiles(id) on delete set null,
  display_name text,
  credit_label text,                       -- e.g. 'Author', 'SME', 'Reviewer'
  sort         int not null default 0,
  created_at   timestamptz not null default now(),
  constraint course_authors_has_identity check (profile_id is not null or display_name is not null)
);
create index on course_authors(course_id);
create index on course_authors(profile_id);

-- ===================== COMING-SOON "NOTIFY ME" REQUESTS ===================
create table course_notify_requests (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references courses(id) on delete cascade,
  profile_id   uuid references profiles(id) on delete set null,
  email        text,
  requested_at timestamptz not null default now(),
  notified_at  timestamptz,
  constraint course_notify_has_contact check (profile_id is not null or email is not null)
);
create index on course_notify_requests(course_id);

-- ============================ SEED DEFAULTS ================================
-- Platform-owner-editable default retake/retry policy per pricing mechanism.
insert into pricing_defaults (pricing_type, assessment_retry_limit, retake_after_pass, retake_limit, access_revoked_on_pass) values
  ('free',                     -1, 'unlimited', null, false),
  ('one_off',                  -1, 'none',      null, true),   -- pay to take; retry to pass, no retakes
  ('credits',                  -1, 'none',      null, true),
  ('included_in_subscription', -1, 'unlimited', null, false), -- unlimited while subscribed
  ('pay_as_you_go',            -1, 'none',      null, true);  -- closes once passed

-- ===================== BACKFILL EXISTING COURSES ==========================
-- One pricing row per course, deriving the mechanism from the mock seed
-- (price → one_off, else credits → credits, else free). Real data reshaped.
insert into course_pricing (course_id, pricing_type, price_pennies, credit_cost)
select
  c.id,
  case
    when coalesce(c.price_pennies, 0) > 0 then 'one_off'::pricing_type
    when coalesce(c.credits, 0) > 0       then 'credits'::pricing_type
    else 'free'::pricing_type
  end,
  c.price_pennies,
  c.credits
from courses c
on conflict (course_id) do nothing;

-- ========================= ROW-LEVEL SECURITY =============================
alter table pricing_defaults       enable row level security;
alter table course_pricing         enable row level security;
alter table territories            enable row level security;
alter table course_territories     enable row level security;
alter table course_authors         enable row level security;
alter table course_notify_requests enable row level security;

-- platform-owned vocabularies / defaults: everyone reads, owner writes.
create policy pricing_defaults_read   on pricing_defaults for select using ( auth.uid() is not null );
create policy pricing_defaults_manage on pricing_defaults for all
  using ( auth_role() = 'bespokelms_owner' ) with check ( auth_role() = 'bespokelms_owner' );
create policy territories_read   on territories for select using ( auth.uid() is not null );
create policy territories_manage on territories for all
  using ( auth_role() = 'bespokelms_owner' ) with check ( auth_role() = 'bespokelms_owner' );

-- course-linked rows: readable if you can see the course; managed by whoever
-- may manage the course (per 003's can_manage_course).
create policy course_pricing_read   on course_pricing for select using ( can_see_course(course_id) );
create policy course_pricing_manage on course_pricing for all
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );

create policy course_territories_read   on course_territories for select using ( can_see_course(course_id) );
create policy course_territories_manage on course_territories for all
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );

create policy course_authors_read   on course_authors for select using ( can_see_course(course_id) );
create policy course_authors_manage on course_authors for all
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );

-- notify-me: any authenticated visitor may register interest in a course they
-- can see; only course managers may read/triage the requests.
create policy notify_insert on course_notify_requests for insert
  with check ( auth.uid() is not null and can_see_course(course_id) );
create policy notify_read   on course_notify_requests for select using ( can_manage_course(course_id) );
create policy notify_update on course_notify_requests for update
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );

-- ============================ GRANTS =======================================
grant select on
  pricing_defaults, course_pricing, territories, course_territories,
  course_authors, course_notify_requests, v_course_effective_pricing
  to anon, authenticated;
grant insert, update, delete on
  pricing_defaults, course_pricing, territories, course_territories,
  course_authors, course_notify_requests
  to authenticated;                          -- gated by the RLS policies above
