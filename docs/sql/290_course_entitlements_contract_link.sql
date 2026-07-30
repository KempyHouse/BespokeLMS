-- 290: a contractual entitlement should say which contract it comes from.
--
-- RAISED BY ANDREW, 29 July 2026, on being told that two of Turner Price's
-- contracted courses needed no entitlement because they were globally scoped:
-- "if the global changes then Turner Price looses it. I think it should be
-- tied to the contract because that's what they are paying for."
--
-- He was right, and the problem was worse than the scope risk he identified.
--
-- 1. SCOPE DRIFT. course_visible_to_org short-circuits on 'global' — a
--    globally scoped course never consults entitlements at all. A course given
--    away today and tightened to 'allowlist' tomorrow silently removes it from
--    a tenant that is contractually owed it. An entitlement row costs nothing
--    while the course is global and catches it the moment it is not.
--
-- 2. DESTRUCTIVE REWRITE, the bigger one. The course editor's tenant-licensing
--    save deletes EVERY entitlement for a course and re-inserts from the form
--    (CourseEditorController), hardcoding license_terms to an empty object. So
--    Turner Price's Schedule 3 entitlements were one routine edit of any of
--    those courses away from disappearing, with nothing left to say they had
--    ever been owed.
--
-- contract_id makes contractual grants identifiable, so they can be protected
-- rather than trusted to whoever last opened the licensing tab. The
-- accompanying application change scopes that screen's delete and its read to
-- `contract_id is null`, and lists contractual grants read-only beneath.
--
-- Nullable on purpose: most entitlements are discretionary and belong to no
-- contract. The column records the distinction between "we chose to grant
-- this" and "we are obliged to", which is what was missing.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29.

alter table public.course_entitlements
    add column contract_id uuid references public.contracts (id) on delete set null;

comment on column public.course_entitlements.contract_id is
  'The contract that obliges this entitlement, when there is one. Null means a discretionary grant. A row with a contract_id must not be removed by ordinary catalogue editing -- ending it is a contractual act.';

create index course_entitlements_contract_idx
    on public.course_entitlements (contract_id) where contract_id is not null;

-- Backfill the Turner Price grants made earlier the same day, which recorded
-- the contract reference as a string in license_terms.
update public.course_entitlements e
set contract_id = c.id
from public.contracts c
where c.reference = 'TP-SAAS-2026-001'
  and e.license_terms->>'contract' = 'TP-SAAS-2026-001'
  and e.contract_id is null;

-- "Are we delivering what we sold" should be a query, not an afternoon.
create view public.v_contracted_course_entitlements as
select
    ct.id                as contract_id,
    ct.reference         as contract_reference,
    ct.title             as contract_title,
    ct.status            as contract_status,
    o.id                 as organization_id,
    o.name               as organization_name,
    co.id                as course_id,
    co.title             as course_title,
    e.state,
    e.license_terms->>'phase' as phase,
    e.valid_from,
    e.valid_until,
    coalesce(cv.scope::text, case when co.owner_org_id is null then 'global' else 'private' end) as course_scope,
    public.course_visible_to_org(o.id, co.id) as visible_now
from public.course_entitlements e
join public.contracts ct on ct.id = e.contract_id
join public.organizations o on o.id = e.org_node_id
join public.courses co on co.id = e.course_id
left join public.course_visibility cv on cv.course_id = co.id;

comment on view public.v_contracted_course_entitlements is
  'Every course a contract obliges, per tenant, with whether it is actually visible to them right now. A false in visible_now against an active contract is a delivery failure.';

-- security_invoker, for the reason recorded in migration 287: a view over an
-- RLS-protected table otherwise runs with the owner's rights and reads past
-- every policy.
alter view public.v_contracted_course_entitlements set (security_invoker = on);
