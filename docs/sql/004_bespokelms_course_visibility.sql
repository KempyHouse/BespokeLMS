-- ===========================================================================
-- BespokeLMS — Schema migration 004 (Global Courses console · Phase 2)
-- Target: Supabase / Postgres.  Depends on 001 + 002 + 003.
--
-- Phase 2: tenant VISIBILITY / ENTITLEMENT — "which tenants can see each
-- course", enforced in the database (RLS), inheriting down the org tree.
--   · scope = global    → every tenant (the Global Catalogue default)
--   · scope = allowlist  → only tenants with a granted entitlement (inherited)
--   · scope = private    → the owning org + its subtree only (operator courses)
--   · scope = denylist   → everyone EXCEPT tenants with a revoked entitlement
-- Plus: tighten the Phase-1 catalogue reads (which were authenticated-parity)
-- onto this model, so a query bug can never leak another operator's courses.
--
-- Additive + declarative.  Backfill: all existing (platform-owned) courses are
-- marked `global`, matching the page tagline "cascade to every tenant".
-- Validated on real Postgres 16 against 001+002+003.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type course_visibility_scope as enum ('global','allowlist','private','denylist');
create type entitlement_state       as enum ('granted','revoked');

-- ========================= VISIBILITY / ENTITLEMENT =======================
create table course_visibility (
  course_id  uuid primary key references courses(id) on delete cascade,
  scope      course_visibility_scope not null default 'global',
  updated_by uuid references profiles(id),
  updated_at timestamptz not null default now()
);

-- Grants/revokes against an org-tree NODE; inherit down the subtree.  Used by
-- allowlist (granted) and denylist (revoked), and to license premium global
-- courses to specific operators (license_terms / seat_cap / validity window).
create table course_entitlements (
  id            uuid primary key default gen_random_uuid(),
  course_id     uuid not null references courses(id) on delete cascade,
  org_node_id   uuid not null references organizations(id) on delete cascade,
  state         entitlement_state not null default 'granted',
  license_terms jsonb not null default '{}'::jsonb,
  seat_cap      int,
  valid_from    timestamptz,
  valid_until   timestamptz,
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now(),
  unique (course_id, org_node_id, state)
);
create index on course_entitlements(course_id);
create index on course_entitlements(org_node_id);

-- ===================== RESOLVERS + VISIBILITY RULE ========================
-- Missing Phase-1 resolvers: owning course id from a slide, and a dispatcher
-- for a translation's entity.  All SECURITY DEFINER (bypass RLS, no recursion).
create or replace function course_of_slide(sid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select cv.course_id
  from slides s
  join lessons l         on l.id  = s.lesson_id
  join modules m         on m.id  = l.module_id
  join course_versions cv on cv.id = m.course_version_id
  where s.id = sid;
$$;

create or replace function course_of_translation(etype text, eid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select case etype
           when 'course_version' then course_of_version(eid)
           when 'module'         then course_of_module(eid)
           when 'lesson'         then course_of_lesson(eid)
           when 'slide'          then course_of_slide(eid)
         end;
$$;

-- Can the CALLER's tenant see this course?
--   platform owner → always · anyone who can MANAGE it → yes (console needs it)
--   otherwise apply the effective scope over the org tree + entitlements.
-- Effective scope falls back safely when no row exists: platform course → global,
-- operator course → private (never accidentally expose an operator's content).
create or replace function can_see_course(cid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with me as (select auth_org_id() as org),
  cv as (
    select
      coalesce(v.scope,
        case when c.owner_org_id is null
             then 'global'::course_visibility_scope
             else 'private'::course_visibility_scope end) as scope,
      c.owner_org_id
    from courses c
    left join course_visibility v on v.course_id = c.id
    where c.id = cid
  )
  select
    auth_role() = 'bespokelms_owner'
    or can_manage_course(cid)
    or exists (
      select 1 from cv
      where
        -- the owning org and its subtree always see it
        (cv.owner_org_id is not null
           and (select org from me) in (select org_and_descendants(cv.owner_org_id)))
        or cv.scope = 'global'
        or (cv.scope = 'allowlist' and exists (
              select 1 from course_entitlements e
              where e.course_id = cid and e.state = 'granted'
                and (e.valid_from  is null or e.valid_from  <= now())
                and (e.valid_until is null or e.valid_until >= now())
                and (select org from me) in (select org_and_descendants(e.org_node_id))))
        or (cv.scope = 'denylist' and not exists (
              select 1 from course_entitlements e
              where e.course_id = cid and e.state = 'revoked'
                and (e.valid_from  is null or e.valid_from  <= now())
                and (e.valid_until is null or e.valid_until >= now())
                and (select org from me) in (select org_and_descendants(e.org_node_id))))
    );
$$;

-- ===================== BACKFILL EXISTING SEED =============================
-- Every seeded course is platform-owned → visible to all tenants (global).
insert into course_visibility (course_id, scope)
select id, 'global' from courses
on conflict (course_id) do nothing;

-- ========================= ROW-LEVEL SECURITY =============================
alter table course_visibility   enable row level security;
alter table course_entitlements enable row level security;

-- visibility/entitlement rows are admin surfaces (who manages the course)
create policy visibility_manage on course_visibility for all
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );
create policy entitlements_manage on course_entitlements for all
  using ( can_manage_course(course_id) ) with check ( can_manage_course(course_id) );

-- ---- Tighten Phase-1 catalogue reads onto the visibility model -----------
drop policy if exists courses_read      on courses;
drop policy if exists versions_read     on course_versions;
drop policy if exists modules_read      on modules;
drop policy if exists lessons_read      on lessons;
drop policy if exists slides_read       on slides;
drop policy if exists translations_read on content_translations;

create policy courses_read on courses for select
  using ( can_see_course(id) );

-- learners see only the published version(s); managers see drafts too
create policy versions_read on course_versions for select
  using ( can_see_course(course_id)
          and (status = 'published' or can_manage_course(course_id)) );

create policy modules_read on modules for select
  using ( can_see_course(course_of_version(course_version_id)) );
create policy lessons_read on lessons for select
  using ( can_see_course(course_of_module(module_id)) );
create policy slides_read on slides for select
  using ( can_see_course(course_of_lesson(lesson_id)) );
create policy translations_read on content_translations for select
  using ( can_see_course(course_of_translation(entity_type, entity_id)) );

-- ============================ GRANTS =======================================
grant select on course_visibility, course_entitlements to anon, authenticated;
grant insert, update, delete on course_visibility, course_entitlements
  to authenticated;                        -- gated by the RLS policies above
grant execute on function
  course_of_slide(uuid), course_of_translation(text, uuid), can_see_course(uuid)
  to anon, authenticated;

-- NOTE: privileged Laravel authoring/console reads run with the service-role key
-- (bypasses RLS); these policies are defence-in-depth for the anon/publishable
-- key so tenant isolation holds even against a direct-client query bug.
