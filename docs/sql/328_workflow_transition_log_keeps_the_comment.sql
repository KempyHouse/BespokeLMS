-- ============================================================================
-- 328 — The transition log had nowhere to put what somebody said
-- ============================================================================
--
-- course_workflow_history carried a `comment`, and the workflow screen shows it:
-- "Published via course editor", or a reviewer's reason for requesting changes.
-- workflow_transition_log shipped in 323 with waiver_reason and no comment, so
-- repointing the application at it would have silently dropped the one part of
-- the record written by a person rather than by the machine.
--
-- waiver_reason IS NOT THE SAME FIELD, and reusing it would have been worse than
-- losing the comment. A waiver justifies overriding a check that failed; a
-- comment is what the actor wanted the next reader to know. Filing ordinary
-- review notes under waiver_reason would make any report of waivers untrue —
-- and a report of waivers is exactly the kind of thing somebody eventually asks
-- an accreditation platform for.
--
-- Found by writing the application change rather than by reading the schema: the
-- history query in CourseWorkflowController asked for a column the new table did
-- not have. Worth noting because it is an argument for repointing the code before
-- declaring a schema finished.
-- ============================================================================

alter table workflow_transition_log add column comment text;

comment on column workflow_transition_log.comment is
    'What the actor said when they made this transition. Distinct from waiver_reason, which justifies overriding a failed check - conflating the two would make any report of waivers untrue.';

-- Carry over what the legacy history holds, so the screen reads the same after
-- the application is repointed.
update workflow_transition_log l
set comment = h.comment
from course_workflow_history h
where l.subject_type = 'course_version'
  and l.subject_id = h.course_version_id
  and l.to_state_id = h.to_state_id
  and l.action = h.action
  and l.comment is null
  and h.comment is not null;
