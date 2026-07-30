-- ============================================================================
-- 325 — The tenant guard treated "platform-owned" as "does not exist"
-- ============================================================================
--
-- FOUND BY TESTING THE GUARD RATHER THAN ASSUMING IT, immediately after 323. A
-- probe that put a real course version into the course workflow was refused
-- with:
--
--   WF-SUBJ-002: no course_version exists with id 8400f2ce-d7e4-4570-a212-...
--
-- which was untrue. The row was right there.
--
-- THE CAUSE. workflow_subject_org() returns the subject's organisation, and the
-- guard read NULL as "not found". But courses.owner_org_id is NULL for ALL 72
-- courses on this platform — NULL means the PLATFORM owns the course, which is
-- the normal and overwhelmingly common case, not an absence. So the guard as
-- shipped in 323 would have refused to record workflow state for every course in
-- existence, and the first person to try would have been told the course was not
-- there.
--
-- WHY IT MATTERS BEYOND THE BUG. Conflating "no organisation" with "no row" is
-- the same shape of mistake as conflating "never ran" with "ran and found
-- nothing" — the one the platform health page exists to catch. A nullable
-- ownership column needs its own existence question, asked separately, because
-- the answer NULL is data.
-- ============================================================================

create or replace function workflow_subject_exists(p_subject_type workflow_subject_type, p_subject_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
    select case p_subject_type
        when 'course_version' then exists (select 1 from course_versions cv where cv.id = p_subject_id)
        when 'esign_document' then exists (select 1 from esign_documents d where d.id = p_subject_id)
        else false
    end
$fn$;

comment on function workflow_subject_exists(workflow_subject_type, uuid) is
    'Whether the subject row is there at all. Separate from workflow_subject_org() because a NULL organisation is a legitimate answer meaning platform-owned, and reading it as "missing" refused every course on the platform.';

create or replace function workflow_subject_org(p_subject_type workflow_subject_type, p_subject_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
    select case p_subject_type
        when 'course_version' then (
            select c.owner_org_id
            from course_versions cv
            join courses c on c.id = cv.course_id
            where cv.id = p_subject_id
        )
        when 'esign_document' then (
            select d.owning_organization_id
            from esign_documents d
            where d.id = p_subject_id
        )
    end
$fn$;

comment on function workflow_subject_org(workflow_subject_type, uuid) is
    'The organisation a workflow subject belongs to, or NULL when the platform owns it. NULL is an answer, not a failure — use workflow_subject_exists() to ask whether the row is there.';

create or replace function workflow_subject_tenant_guard()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
    v_workflow_org uuid;
    v_workflow_subject workflow_subject_type;
    v_subject_org uuid;
begin
    select w.owning_organization_id, w.subject_type
    into v_workflow_org, v_workflow_subject
    from workflow_versions v
    join workflows w on w.id = v.workflow_id
    where v.id = new.workflow_version_id;

    if v_workflow_subject is distinct from new.subject_type then
        raise exception
            'WF-SUBJ-001: this workflow governs % and was handed a %. A workflow cannot be pointed at a subject of a different type.',
            v_workflow_subject, new.subject_type;
    end if;

    -- Existence asked on its own, because the next question's answer may
    -- legitimately be NULL.
    if not workflow_subject_exists(new.subject_type, new.subject_id) then
        raise exception
            'WF-SUBJ-002: no % exists with id %. A workflow cannot record the position of something that is not there.',
            new.subject_type, new.subject_id;
    end if;

    v_subject_org := workflow_subject_org(new.subject_type, new.subject_id);

    -- A PLATFORM workflow (null organisation) governs any subject, tenant-owned
    -- or platform-owned. A TENANT'S OWN workflow governs only that tenant's
    -- subjects — including refusing a platform-owned subject, because a tenant
    -- must not be able to put shared content through its private approval path
    -- and thereby change what every other tenant sees.
    if v_workflow_org is not null and (v_subject_org is null or v_workflow_org <> v_subject_org) then
        raise exception
            'WF-SUBJ-003: this workflow belongs to organisation % and the subject belongs to %. Tenant isolation refuses the row.',
            v_workflow_org, coalesce(v_subject_org::text, 'the platform');
    end if;

    return new;
end $fn$;

revoke execute on function workflow_subject_exists(workflow_subject_type, uuid) from public, anon, authenticated;
revoke execute on function workflow_subject_org(workflow_subject_type, uuid) from public, anon, authenticated;
revoke execute on function workflow_subject_tenant_guard() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The six probes this migration was verified against, for whoever changes the
-- guard next. Each was run and each behaved as stated.
--
--   1. a platform-owned course version into the platform course workflow  ACCEPTED
--   2. an esign_document into a course workflow                           WF-SUBJ-001
--   3. a course version id that does not exist                            WF-SUBJ-002
--   4. a second platform workflow reusing the state key 'draft'           ACCEPTED (see 326)
--   5. an esign_document into an esign workflow                           ACCEPTED
--   6. a tenant's own workflow reaching for platform-owned content        WF-SUBJ-003
-- ---------------------------------------------------------------------------
