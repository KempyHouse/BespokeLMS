-- 291: content you sell cannot be given to the whole platform by accident.
--
-- RAISED BY ANDREW, 29 July 2026: "Those two global courses are visible to
-- every tenant on the platform — including any future competitor of Turner
-- Price. If CPD catering content is meant to be sold rather than given away,
-- global is the wrong scope for them."
--
-- THE HOLE. course_visibility.scope = 'global' was a single unguarded switch,
-- and course_visible_to_org short-circuits on it without consulting
-- entitlements at all. One dropdown made a course free to every tenant on the
-- estate, for ever, with nothing recording that anyone had decided it should
-- be. Three courses were in that state and nobody chose it.
--
-- THE SHAPE IS THE NAVIGATION ONE, because it is proven in this platform: a
-- declared classification, a guard that refuses the write with a sentence a
-- person can act on, a recorded exception for the deliberate case, a drift
-- view for rows that predate the guard, and a monitor so drift is noticed
-- rather than discovered. The same parts as route ownership,
-- nav_version_publish_guard, nav_ownership_exceptions, v_nav_menu_drift and
-- monitor_nav_drift.
--
-- DEFAULT IS 'licensed', agreed with Andrew. Content is the product, so the
-- safe default is that it is sold. Marking something 'open' then becomes a
-- decision somebody made, which is the whole point.
--
-- APPLIED ALONGSIDE THIS, as data rather than schema: Food Allergen Awareness
-- and Allergic Reactions & Anaphylaxis were scoped from global to allowlist.
-- Both already entitled exactly Turner Price and FoodComplianceHQ, so nobody
-- licensed lost anything. Food Hygiene & Safety Level 2 for Primary Schools
-- was deliberately NOT scoped down: only FoodComplianceHQ is entitled, so
-- tightening it would remove a primary-schools course from TeachHQ, the
-- education operator, which reads as collateral rather than intent.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29.

create type public.course_distribution_class as enum ('licensed', 'open');

alter table public.courses
    add column distribution_class public.course_distribution_class not null default 'licensed';

comment on column public.courses.distribution_class is
  'Whether this course may be given to the whole platform. licensed (the default) means entitlement-gated and refused global scope without a recorded exception; open means deliberately free to every tenant.';

create index courses_distribution_class_idx on public.courses (distribution_class);

create table public.course_visibility_exceptions (
    course_id uuid primary key references public.courses (id) on delete cascade,
    reason text not null check (length(btrim(reason)) > 0),
    approved_by uuid references public.profiles (id),
    approved_at timestamptz not null default now()
);

comment on table public.course_visibility_exceptions is
  'A licensed course allowed to be globally visible anyway, with the reason and who approved it. Without a row here the guard refuses global scope on licensed content.';

alter table public.course_visibility_exceptions enable row level security;

create policy course_visibility_exceptions_owner on public.course_visibility_exceptions
    for all using (exists (
        select 1 from public.profiles p where p.auth_user_id = auth.uid() and p.role = 'bespokelms_owner'))
    with check (exists (
        select 1 from public.profiles p where p.auth_user_id = auth.uid() and p.role = 'bespokelms_owner'));

create or replace function public.course_visibility_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_class public.course_distribution_class;
    v_title text;
begin
    if new.scope is distinct from 'global' then
        return new;
    end if;

    select c.distribution_class, c.title into v_class, v_title
      from courses c where c.id = new.course_id;

    if v_class is distinct from 'licensed' then
        return new;
    end if;

    if exists (select 1 from course_visibility_exceptions x where x.course_id = new.course_id) then
        return new;
    end if;

    raise exception using errcode = 'check_violation',
        message = format(
            '%s is licensed content, so it cannot be made globally visible: every tenant on the platform would get it free, including competitors of the tenants paying for it. Either license it to the tenants who should have it (course_entitlements, with scope allowlist), or -- if it really is meant to be free to everyone -- set courses.distribution_class to ''open'', or record an approved exception in course_visibility_exceptions saying why.',
            coalesce(v_title, 'This course'));
end;
$$;

create trigger course_visibility_guard_trg
    before insert or update of scope on public.course_visibility
    for each row execute function public.course_visibility_guard();

create view public.v_course_visibility_drift as
select
    c.id as course_id, c.title as course_title, c.distribution_class,
    coalesce(v.scope::text, case when c.owner_org_id is null then 'global' else 'private' end) as scope,
    (x.course_id is not null) as has_exception,
    x.reason as exception_reason,
    (select count(*) from course_entitlements e where e.course_id = c.id) as entitlements,
    (select count(*) from course_entitlements e where e.course_id = c.id and e.contract_id is not null) as contractual_entitlements,
    'COURSE-VIS-001' as code,
    format('%s is licensed content but is visible to every tenant on the platform. Either license it to the tenants who should have it, mark it open, or record an approved exception.', c.title) as detail
from public.courses c
left join public.course_visibility v on v.course_id = c.id
left join public.course_visibility_exceptions x on x.course_id = c.id
where c.distribution_class = 'licensed'
  and coalesce(v.scope::text, case when c.owner_org_id is null then 'global' else 'private' end) = 'global'
  and x.course_id is null;

comment on view public.v_course_visibility_drift is
  'Licensed courses that are globally visible without an approved exception. Each row is paid content the whole estate can currently see for nothing.';

alter view public.v_course_visibility_drift set (security_invoker = on);

create or replace function public.monitor_course_visibility(out finding_count integer, out summary text)
returns record
language plpgsql
security definer
set search_path to 'public'
as $$
begin
    select count(*) into finding_count from v_course_visibility_drift;

    summary := case when finding_count = 0
                    then 'No licensed course is globally visible without an approved exception.'
                    else format('%s licensed course(s) are free to every tenant on the platform.', finding_count) end;
end;
$$;

revoke execute on function public.monitor_course_visibility() from public;
revoke execute on function public.course_visibility_guard() from public;

insert into public.platform_monitors (key, name, tier, check_function, question, remedy, enabled)
values (
    'course_visibility',
    'Paid content given away platform-wide',
    1,
    'monitor_course_visibility',
    'can every tenant see a course we sell, including competitors of the tenants paying for it?',
    'Run: select * from v_course_visibility_drift. For each row, either license it to the tenants who should have it (course_entitlements, scope allowlist), or set courses.distribution_class to ''open'' if it is genuinely free to everyone, or record the deliberate case in course_visibility_exceptions with a reason. Scoping a course down removes it from every tenant that has no entitlement, so grant first and tighten second.',
    true
)
on conflict (key) do nothing;
