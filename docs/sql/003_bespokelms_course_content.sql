-- ===========================================================================
-- BespokeLMS — Schema migration 003 (Global Courses console · Phase 1)
-- Target: Supabase / Postgres.  Depends on 001_bespokelms_schema.sql (+002 seed).
--
-- Phase 1 of the Global Courses management console: turn the flat `courses`
-- table into a proper authoring model with the TWO-AXIS design —
--   editorial VERSION (course_versions, immutable-on-publish snapshots)  ×
--   language VARIANT  (content_translations, per-locale).
-- Native slide content (image_text | video | document) lives in
-- modules → lessons → slides.  SCORM import, workflow, taxonomy overlay,
-- visibility/entitlement and voiceover arrive in later migrations (Phase 2+).
--
-- Additive + declarative.  RLS on every new table, cascading down the org tree
-- exactly like migration 001.  All existing seeded courses are backfilled into
-- a v1.0 course_version and every enrolment is pinned to it — no mock data is
-- invented, the current seed is reshaped in place.
--
-- Safe to run once, after 001/002, on the BespokeLMS project (pqmdtqsscyltykgcwwus).
-- ===========================================================================

create extension if not exists pg_trgm;

-- ============================ ENUMS ========================================
create type content_type       as enum ('native','scorm','mixed');
create type version_status      as enum ('draft','published','archived');
create type slide_type          as enum ('image_text','video','document');
create type translation_status  as enum ('missing','draft','reviewed','published');
create type version_migration_policy as enum ('finish_then_switch','force_recert');

-- ==================== COURSES → IDENTITY SHELL =============================
-- Keep every existing column (title/description/category_id/catalog_status/…);
-- the editable content now lives in course_versions and below.  These columns
-- turn `courses` into the stable identity + catalogue-facing shell.
alter table courses
  add column slug                         text,
  add column content_type                 content_type not null default 'native',
  add column current_published_version_id uuid,
  add column created_by                   uuid references profiles(id),
  add column updated_at                   timestamptz not null default now();

-- Backfill a unique slug from the title (+ short id suffix → guaranteed unique).
update courses
   set slug = lower(regexp_replace(
                regexp_replace(title, '[^a-zA-Z0-9]+', '-', 'g'),
                '(^-+|-+$)', '', 'g'))
              || '-' || left(replace(id::text, '-', ''), 6);

alter table courses alter column slug set not null;
create unique index courses_slug_key on courses(slug);
create index on courses(content_type);

-- Full-text search vector (title + description + accreditation), GIN-indexed,
-- plus a trigram index on title for fuzzy / partial matches.  Native Postgres
-- search is sufficient at hundreds–thousands of courses (no external engine).
alter table courses
  add column search_vector tsvector
  generated always as (
    to_tsvector('english',
      coalesce(title, '') || ' ' ||
      coalesce(description, '') || ' ' ||
      coalesce(accreditation, ''))
  ) stored;
create index courses_search_vector_idx on courses using gin (search_vector);
create index courses_title_trgm_idx    on courses using gin (title gin_trgm_ops);

-- ========================= COURSE VERSIONS =================================
-- One editorial revision of a course.  A published version is an immutable
-- snapshot; editing creates a new draft.  Enrolments pin to a version so a
-- learner mid-course keeps the version they started.
create table course_versions (
  id                uuid primary key default gen_random_uuid(),
  course_id         uuid not null references courses(id) on delete cascade,
  version_no        int  not null,                    -- monotonic, for ordering/FKs
  semver            text not null default '1.0.0',    -- display version
  status            version_status not null default 'draft',
  title             text,                             -- base-locale snapshot (nullable → inherit course.title)
  summary           text,
  changelog         text,                             -- author "what changed" note
  is_scorm          boolean not null default false,   -- true → content is a SCORM package (Phase 2)
  review_interval   interval,                         -- e.g. '12 months'
  review_due_at     timestamptz,
  migration_policy  version_migration_policy not null default 'finish_then_switch',
  published_at      timestamptz,
  published_by      uuid references profiles(id),
  created_by        uuid references profiles(id),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (course_id, version_no)
);
create index on course_versions(course_id);
create index on course_versions(status);

-- courses.current_published_version_id → the live version (added after the
-- target table exists to satisfy the FK).
alter table courses
  add constraint courses_current_version_fk
  foreign key (current_published_version_id)
  references course_versions(id) on delete set null;

-- ===================== NATIVE CONTENT TREE ================================
-- module → lesson → slide.  The `module` level is kept even when a course has
-- only one; adding a hierarchy level later is a painful migration, an always-
-- present "Module 1" costs nothing.
create table modules (
  id                uuid primary key default gen_random_uuid(),
  course_version_id uuid not null references course_versions(id) on delete cascade,
  title             text not null,
  position          int  not null default 0,
  created_at        timestamptz not null default now()
);
create index on modules(course_version_id);

create table lessons (
  id          uuid primary key default gen_random_uuid(),
  module_id   uuid not null references modules(id) on delete cascade,
  title       text not null,
  position    int  not null default 0,
  created_at  timestamptz not null default now()
);
create index on lessons(module_id);

-- Heterogeneous slide types in ONE table: shared spine + typed jsonb payload.
-- payload shape is validated in the Laravel Form Request per slide type;
-- fields we filter/sort on often are promoted to real columns later.
--   image_text : { "body_html", "image_path", "image_alt", "layout" }
--   video      : { "provider", "video_url", "poster_path", "captions_path", "duration_seconds" }
--   document   : { "document_path", "mime", "page_count", "require_scroll_complete" }
create table slides (
  id              uuid primary key default gen_random_uuid(),
  lesson_id       uuid not null references lessons(id) on delete cascade,
  position        int  not null default 0,
  type            slide_type not null,
  title           text,
  payload         jsonb not null default '{}'::jsonb,
  is_required     boolean not null default true,        -- counts toward completion
  completion_rule jsonb not null default '{}'::jsonb,   -- e.g. {"min_view_seconds":10} / {"video_watch_pct":90}
  base_locale     text not null default 'en',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index on slides(lesson_id);
create index on slides(type);

-- ====================== LANGUAGE VARIANTS =================================
-- The language axis: per-locale text for any translatable entity, tracked with
-- its own status (AI-drafted → human-reviewed → published) so English can be
-- live while other locales are still in review.
create table content_translations (
  id           uuid primary key default gen_random_uuid(),
  entity_type  text not null,        -- 'course_version' | 'module' | 'lesson' | 'slide'
  entity_id    uuid not null,
  locale       text not null,        -- BCP-47, e.g. 'en','fr','cy'
  fields       jsonb not null default '{}'::jsonb,   -- translated field map
  status       translation_status not null default 'draft',
  reviewed_by  uuid references profiles(id),
  reviewed_at  timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (entity_type, entity_id, locale)
);
create index on content_translations(entity_type, entity_id);
create index on content_translations(locale);

-- ================== ENROLMENTS: PIN TO A VERSION ==========================
alter table enrollments
  add column course_version_id    uuid references course_versions(id),
  add column certificate_expires_at timestamptz;
create index on enrollments(course_version_id);

-- ===================== BACKFILL EXISTING SEED =============================
-- Reshape the 28 seeded courses into the two-axis model (real data, not mock):
--  · published courses  → a published v1.0 version (published_at = created_at)
--  · coming_soon courses → a draft v1.0 version (no live version yet)
--  · retired courses     → an archived v1.0 version
insert into course_versions
  (course_id, version_no, semver, status, title, summary, is_scorm, published_at, created_at)
select
  c.id, 1, '1.0.0',
  case c.catalog_status
    when 'published' then 'published'::version_status
    when 'retired'   then 'archived'::version_status
    else 'draft'::version_status
  end,
  c.title, c.description, false,
  case when c.catalog_status = 'published' then c.created_at end,
  c.created_at
from courses c;

-- Point each published course at its live version.
update courses c
   set current_published_version_id = cv.id
  from course_versions cv
 where cv.course_id = c.id
   and cv.status = 'published';

-- Pin every existing enrolment to the course's v1 version.
update enrollments e
   set course_version_id = cv.id
  from course_versions cv
 where cv.course_id = e.course_id;

-- =============== RBAC HELPERS FOR CONTENT MANAGEMENT ======================
-- Who may WRITE course content:
--   · platform courses (owner_org_id is null) → the platform owner only
--   · operator courses (owner_org_id set)     → an admin within that org subtree
-- SECURITY DEFINER so the resolvers/policies never recurse into RLS.
create or replace function can_manage_course(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from courses c
    where c.id = cid
      and (
        (c.owner_org_id is null  and auth_role() = 'bespokelms_owner')
        or
        (c.owner_org_id is not null
           and is_admin()
           and c.owner_org_id in (select org_and_descendants(auth_org_id())))
      )
  );
$$;

-- Resolvers: owning course id from a version/module/lesson (bypass RLS).
create or replace function course_of_version(vid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select course_id from course_versions where id = vid;
$$;

create or replace function course_of_module(mid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select cv.course_id
  from modules m join course_versions cv on cv.id = m.course_version_id
  where m.id = mid;
$$;

create or replace function course_of_lesson(lid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select cv.course_id
  from lessons l
  join modules m        on m.id  = l.module_id
  join course_versions cv on cv.id = m.course_version_id
  where l.id = lid;
$$;

-- ========================= ROW-LEVEL SECURITY =============================
alter table course_versions      enable row level security;
alter table modules              enable row level security;
alter table lessons              enable row level security;
alter table slides               enable row level security;
alter table content_translations enable row level security;

-- READ: any authenticated tenant member may read course content (catalogue
-- parity with migration 001's courses_read).  Phase 2 tightens reads to the
-- per-tenant visibility/entitlement model.
create policy versions_read     on course_versions      for select using ( auth.uid() is not null );
create policy modules_read      on modules              for select using ( auth.uid() is not null );
create policy lessons_read      on lessons              for select using ( auth.uid() is not null );
create policy slides_read       on slides               for select using ( auth.uid() is not null );
create policy translations_read on content_translations for select using ( auth.uid() is not null );

-- MANAGE: platform-owner for platform courses, org-subtree admins for operator
-- courses — resolved up the tree to the owning course.
create policy versions_manage on course_versions for all
  using      ( can_manage_course(course_id) )
  with check ( can_manage_course(course_id) );

create policy modules_manage on modules for all
  using      ( can_manage_course(course_of_version(course_version_id)) )
  with check ( can_manage_course(course_of_version(course_version_id)) );

create policy lessons_manage on lessons for all
  using      ( can_manage_course(course_of_module(module_id)) )
  with check ( can_manage_course(course_of_module(module_id)) );

create policy slides_manage on slides for all
  using      ( can_manage_course(course_of_lesson(lesson_id)) )
  with check ( can_manage_course(course_of_lesson(lesson_id)) );

-- Translations: authored by owner/operator admins (not client_admin/manager).
-- Per-course precision arrives with the Phase 2 visibility layer.
create policy translations_manage on content_translations for all
  using      ( auth_role() in ('bespokelms_owner','lms_operator_admin') )
  with check ( auth_role() in ('bespokelms_owner','lms_operator_admin') );

-- ============================ GRANTS =======================================
grant select on course_versions, modules, lessons, slides, content_translations
  to anon, authenticated;
grant insert, update, delete on
  course_versions, modules, lessons, slides, content_translations
  to authenticated;                       -- still gated by the RLS policies above
grant execute on function
  can_manage_course(uuid), course_of_version(uuid),
  course_of_module(uuid), course_of_lesson(uuid)
  to anon, authenticated;

-- NOTE: privileged Laravel writes run with the service-role key (bypasses RLS)
-- for authoring flows; the policies above are defence-in-depth for the anon/
-- publishable key, consistent with migration 001.
