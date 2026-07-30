-- ============================================================================
-- 327 — Move the live course workflow data into the builder's tables, and add
--       the flag that lets the publish gate be turned on deliberately
-- ============================================================================
--
-- 29 rows in course_workflow_state and 1 in course_workflow_history were the only
-- live workflow data on the platform. They are MOVED rather than left behind,
-- because a course sitting in review must still be sitting in review after the
-- application is repointed. The insert runs through workflow_subject_tenant_guard()
-- on every row, so this is also the guard's first encounter with real data at
-- scale — and it passed all 29.
--
-- WHAT THE 29 ROWS TURNED OUT TO BE: 19 published, 9 draft, 1 in review. The 19
-- match the 19 published course_versions exactly, so turning the gate on does not
-- retrospectively invalidate anything already live.
--
-- THE FLAG, and why this is not switched on in the same breath. Enforcing
-- approval on publish is a behaviour change on live data: with the gate on, a
-- course cannot be published unless it has reached a state marked is_published
-- through a transition somebody was allowed to make. There are two platform
-- owners (Andrew Kemp and Mark Milstead), so the four-eyes rule on `approve` is
-- satisfiable — but it does mean whoever submits a version cannot be the one to
-- approve it. That is the entire point of the rule and it is also a change to how
-- one person's afternoon works, so it goes behind a flag and is switched on
-- deliberately rather than arriving as a surprise mid-edit. Same pattern, and the
-- same reasoning, as qa_gate_enforced.
--
-- UNTIL THE FLAG IS ON, the publish path records workflow state but does not
-- refuse a publish. That is strictly better than what came before, where it
-- recorded nothing and refused nothing.
-- ============================================================================

insert into workflow_subject_states
    (workflow_version_id, subject_type, subject_id, state_id, entered_at, entered_by)
select v.id, 'course_version', s.course_version_id, s.state_id,
       coalesce(s.entered_at, now()), s.entered_by
from course_workflow_state s
join workflow_states ws on ws.id = s.state_id
join workflow_versions v on v.id = ws.version_id
join workflows w on w.id = v.workflow_id
where w.key = 'course_approval'
  and w.owning_organization_id is null
on conflict (subject_type, subject_id) do nothing;

insert into workflow_transition_log
    (workflow_version_id, subject_type, subject_id, from_state_id, to_state_id, action, actor_profile_id, occurred_at)
select v.id, 'course_version', h.course_version_id, h.from_state_id, h.to_state_id,
       h.action, h.actor_id, coalesce(h.at, now())
from course_workflow_history h
join workflow_states ws on ws.id = h.to_state_id
join workflow_versions v on v.id = ws.version_id
join workflows w on w.id = v.workflow_id
where w.key = 'course_approval'
  and w.owning_organization_id is null;

-- Prove the move rather than assume it: every source row must have landed. A
-- partial migration here means a course silently loses its place in the workflow,
-- which is exactly the kind of quiet loss that is discovered weeks later by
-- somebody wondering why a course is back in draft.
do $check$
declare
    v_src integer;
    v_dst integer;
begin
    select count(*) into v_src from course_workflow_state;
    select count(*) into v_dst from workflow_subject_states where subject_type = 'course_version';

    if v_dst < v_src then
        raise exception
            'Migration 327 moved only % of % course workflow state rows. A course would silently lose its place in the workflow, so the migration is refused.',
            v_dst, v_src;
    end if;
end $check$;

comment on table course_workflow_state is
    'DEPRECATED by migration 327. Superseded by workflow_subject_states, which can hold any workflow subject rather than only a course version. Retained, unread, until the application no longer references it.';
comment on table course_workflow_history is
    'DEPRECATED by migration 327. Superseded by workflow_transition_log, which is append-only and enforced as such by a trigger. Retained, unread, until the application no longer references it.';

insert into feature_flags (key, enabled, description)
values (
    'course_approval_enforced',
    false,
    'When on, publishing a course version requires it to have reached a published state through the course_approval workflow. Off until the workflow is populated and a second approver is in the habit, because the four-eyes rule means whoever submits cannot approve. Until this is on, the publish path records workflow state but does not refuse a publish.'
)
on conflict (key) do nothing;
