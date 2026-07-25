-- 064: "which courses may THIS organisation's marketing site advertise?"
-- APPLIED to pqmdtqsscyltykgcwwus.
--
-- Background. A course with owner_org_id IS NULL is not an unowned course
-- waiting to be tidied up: can_see_course() reads a null owner as scope
-- 'global', meaning a platform catalogue course every tenant may see. All 28
-- courses currently carry an explicit course_visibility.scope = 'global'.
--
-- So filtering the public course block on owner_org_id = <the site's org>
-- (migration-free change shipped in app commit 26a90d6) was wrong: it excludes
-- precisely the shared catalogue that every tenant is supposed to show, and
-- would have blanked the live BespokeLMS homepage's course grid and statistics.
-- The scope still has to exist, or one tenant's site advertises another
-- tenant's private courses — it just has to be the SAME rule the application
-- uses everywhere else.
--
-- Rather than write that rule a second time in PHP, the org-visibility test is
-- extracted here and can_see_course() now calls it. One implementation, so the
-- public site and the signed-in catalogue cannot drift apart.

create or replace function public.course_visible_to_org(p_org uuid, cid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  with cv as (
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
  select exists (
    select 1 from cv
    where
      -- The organisation owns it, or sits under the organisation that does.
      (cv.owner_org_id is not null
         and p_org in (select org_and_descendants(cv.owner_org_id)))
      or cv.scope = 'global'
      or (cv.scope = 'allowlist' and exists (
            select 1 from course_entitlements e
            where e.course_id = cid and e.state = 'granted'
              and (e.valid_from  is null or e.valid_from  <= now())
              and (e.valid_until is null or e.valid_until >= now())
              and p_org in (select org_and_descendants(e.org_node_id))))
      or (cv.scope = 'denylist' and not exists (
            select 1 from course_entitlements e
            where e.course_id = cid and e.state = 'revoked'
              and (e.valid_from  is null or e.valid_from  <= now())
              and (e.valid_until is null or e.valid_until >= now())
              and p_org in (select org_and_descendants(e.org_node_id))))
  );
$$;

-- The signed-in rule is now the org rule plus the two bypasses that only make
-- sense for a person: the platform owner sees everything, and an author sees
-- what they may manage. Behaviour is unchanged; the body is just no longer the
-- only place the org rule is written down.
create or replace function public.can_see_course(cid uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    auth_role() = 'bespokelms_owner'
    or can_manage_course(cid)
    or course_visible_to_org(auth_org_id(), cid);
$$;

-- What a tenant's public marketing site may list. Published only, and only
-- what that organisation could legitimately show.
create or replace function public.public_catalogue(p_org uuid, p_limit integer default 6)
returns table (
  id uuid,
  title text,
  slug text,
  description text,
  thumbnail_path text,
  hero_image_path text,
  hero_image_alt text,
  cpd_points integer,
  accreditation text,
  duration_min integer,
  level text
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select c.id, c.title, c.slug, c.description, c.thumbnail_path, c.hero_image_path,
         c.hero_image_alt, c.cpd_points, c.accreditation, c.duration_min, c.level::text
    from courses c
   where c.catalog_status = 'published'
     and course_visible_to_org(p_org, c.id)
   order by c.title asc
   limit greatest(1, least(24, coalesce(p_limit, 6)));
$$;

-- The statistics block. Category count is how many subject areas this
-- organisation's published catalogue actually covers, not how many rows the
-- shared taxonomy happens to have (course_categories has no owner column, so
-- counting the table would report the same number to every tenant).
create or replace function public.public_catalogue_counts(p_org uuid)
returns table (
  published_courses integer,
  course_categories integer,
  cpd_points integer
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select
    count(*)::integer,
    count(distinct c.category_id)::integer,
    coalesce(sum(c.cpd_points), 0)::integer
    from courses c
   where c.catalog_status = 'published'
     and course_visible_to_org(p_org, c.id);
$$;

-- Only the application reaches these, and it uses the service-role key. An
-- anonymous visitor gets the rendered page, never the function.
revoke all on function public.public_catalogue(uuid, integer) from public, anon, authenticated;
revoke all on function public.public_catalogue_counts(uuid) from public, anon, authenticated;
grant execute on function public.public_catalogue(uuid, integer) to service_role;
grant execute on function public.public_catalogue_counts(uuid) to service_role;
