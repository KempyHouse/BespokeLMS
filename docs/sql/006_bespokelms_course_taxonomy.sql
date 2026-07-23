-- ===========================================================================
-- BespokeLMS — Schema migration 006 (Global Courses console · Phase 7)
-- Target: Supabase / Postgres.  Depends on 001 + 002 + 003 + 004 + 005.
--
-- Phase 7: TAXONOMY + TAGGING with per-tenant OVERRIDE.
--   Global baseline owned by the platform, overlaid per tenant so each
--   white-label LMS can categorise its own way WITHOUT forking the global set.
--   Resolution is always COALESCE(tenant override, global value).
--     · course_categories  → evolved into the global category dictionary
--       (adds parent_id + key; keeps `name` as the label + courses.category_id)
--     · tags / course_tags → global tags + course↔tag (nullable org = private)
--     · tenant_category_overrides → rename / re-parent / hide / re-sort a category
--     · tenant_tags               → a tenant's own private tags
--     · tenant_course_overrides   → re-badge a global course for that tenant
--
-- Additive + declarative.  Taxonomy composes AFTER visibility (a tenant only
-- categorises courses it is entitled to see — migration 004).
-- Validated on real Postgres 16 against 001–005.
-- ===========================================================================

-- =============== GLOBAL CATEGORY DICTIONARY (evolve existing) ==============
alter table course_categories
  add column parent_id uuid references course_categories(id) on delete set null,
  add column key       text;

update course_categories
   set key = lower(regexp_replace(regexp_replace(name,'[^a-zA-Z0-9]+','-','g'),'(^-+|-+$)','','g'));
create unique index course_categories_key_key on course_categories(key);
create index on course_categories(parent_id);

-- ============================ GLOBAL TAGS =================================
create table tags (
  id    uuid primary key default gen_random_uuid(),
  key   text not null unique,
  label text not null,
  sort  int  not null default 0
);

-- course ↔ tag.  organization_id null = a GLOBAL tag assignment (platform);
-- organization_id set = a tenant privately tagging a course it can see.
create table course_tags (
  course_id       uuid not null references courses(id) on delete cascade,
  tag_id          uuid references tags(id) on delete cascade,
  tenant_tag_id   uuid,                              -- set when the tag is a tenant-local tag (see tenant_tags)
  organization_id uuid references organizations(id) on delete cascade,
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now(),
  -- exactly one of (global tag) / (tenant tag) is referenced
  constraint course_tags_one_tag check ( (tag_id is not null) <> (tenant_tag_id is not null) )
);
create index on course_tags(course_id);
create index on course_tags(tag_id);
create index on course_tags(organization_id);
-- de-dupe: same course+tag(+org) only once (nulls-distinct guarded per scope)
create unique index course_tags_global_uq on course_tags(course_id, tag_id) where organization_id is null and tag_id is not null;
create unique index course_tags_tenant_uq on course_tags(course_id, organization_id, coalesce(tag_id, tenant_tag_id)) where organization_id is not null;

-- ===================== PER-TENANT OVERLAY TABLES =========================
-- rename / re-parent / hide / re-order a GLOBAL category, per tenant.
create table tenant_category_overrides (
  organization_id   uuid not null references organizations(id) on delete cascade,
  category_id       uuid not null references course_categories(id) on delete cascade,
  override_label    text,
  override_parent_id uuid references course_categories(id) on delete set null,
  hidden            boolean not null default false,
  sort_order        int,
  updated_by        uuid references profiles(id),
  updated_at        timestamptz not null default now(),
  primary key (organization_id, category_id)
);

-- a tenant's own private tags (alongside the global `tags`).
create table tenant_tags (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references organizations(id) on delete cascade,
  key             text not null,
  label           text not null,
  sort            int  not null default 0,
  unique (organization_id, key)
);
create index on tenant_tags(organization_id);

-- re-badge a GLOBAL course for one tenant's audience.
create table tenant_course_overrides (
  organization_id     uuid not null references organizations(id) on delete cascade,
  course_id           uuid not null references courses(id) on delete cascade,
  override_title      text,
  override_summary    text,
  override_category_id uuid references course_categories(id) on delete set null,
  custom              jsonb not null default '{}'::jsonb,
  updated_by          uuid references profiles(id),
  updated_at          timestamptz not null default now(),
  primary key (organization_id, course_id)
);

-- add course_tags.tenant_tag_id FK now that tenant_tags exists
alter table course_tags
  add constraint course_tags_tenant_tag_fk
  foreign key (tenant_tag_id) references tenant_tags(id) on delete cascade;

-- ===================== RESOLUTION HELPERS ================================
-- effective category label for a tenant = COALESCE(override, global name).
create or replace function resolve_category_label(cid uuid, org uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(o.override_label, c.name)
  from course_categories c
  left join tenant_category_overrides o
    on o.category_id = c.id and o.organization_id = org
  where c.id = cid;
$$;

-- effective course title for a tenant = COALESCE(tenant override, base title).
create or replace function resolve_course_title(cid uuid, org uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(t.override_title, c.title)
  from courses c
  left join tenant_course_overrides t
    on t.course_id = c.id and t.organization_id = org
  where c.id = cid;
$$;

-- ========================= ROW-LEVEL SECURITY ============================
alter table tags                      enable row level security;
alter table course_tags               enable row level security;
alter table tenant_category_overrides enable row level security;
alter table tenant_tags               enable row level security;
alter table tenant_course_overrides   enable row level security;

-- global dictionaries: everyone reads; only the platform owner writes.
create policy tags_read   on tags for select using ( auth.uid() is not null );
create policy tags_manage on tags for all
  using ( auth_role() = 'bespokelms_owner' ) with check ( auth_role() = 'bespokelms_owner' );

-- course_tags: readable if you can see the course; managed by whoever may
-- manage the course (global assignment) or an admin of the tagging org.
create policy course_tags_read on course_tags for select
  using ( can_see_course(course_id) );
create policy course_tags_manage on course_tags for all
  using (
    case when organization_id is null
         then can_manage_course(course_id)
         else is_admin() and organization_id in (select org_and_descendants(auth_org_id()))
    end
  )
  with check (
    case when organization_id is null
         then can_manage_course(course_id)
         else is_admin() and organization_id in (select org_and_descendants(auth_org_id()))
    end
  );

-- tenant overlays: read by any member of that org subtree (so learners see the
-- remapped labels); write by an admin in that subtree.
create policy tco_read   on tenant_category_overrides for select
  using ( organization_id in (select org_and_descendants(auth_org_id())) );
create policy tco_manage on tenant_category_overrides for all
  using ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) )
  with check ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) );

create policy ttags_read   on tenant_tags for select
  using ( organization_id in (select org_and_descendants(auth_org_id())) );
create policy ttags_manage on tenant_tags for all
  using ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) )
  with check ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) );

create policy tcourse_read   on tenant_course_overrides for select
  using ( organization_id in (select org_and_descendants(auth_org_id())) );
create policy tcourse_manage on tenant_course_overrides for all
  using ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) )
  with check ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) );

-- allow the platform owner to manage the (previously read-only) global category
-- dictionary through the app's anon/publishable path too (defence-in-depth).
create policy cats_manage on course_categories for all
  using ( auth_role() = 'bespokelms_owner' ) with check ( auth_role() = 'bespokelms_owner' );

-- ============================ GRANTS =====================================
grant select on tags, course_tags, tenant_category_overrides, tenant_tags, tenant_course_overrides
  to anon, authenticated;
grant insert, update, delete on
  tags, course_tags, tenant_category_overrides, tenant_tags, tenant_course_overrides,
  course_categories
  to authenticated;                          -- gated by the RLS policies above
grant execute on function resolve_category_label(uuid, uuid), resolve_course_title(uuid, uuid)
  to anon, authenticated;

-- NOTE: the console resolves display values with COALESCE(tenant override,
-- global) — the helper functions above encapsulate that so the UI and any
-- report share one definition of a tenant's effective taxonomy.
