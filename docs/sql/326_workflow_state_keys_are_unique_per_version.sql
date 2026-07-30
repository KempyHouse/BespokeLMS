-- ============================================================================
-- 326 — Two indexes *were* the one-workflow-per-organisation rule
-- ============================================================================
--
-- FOUND BY A PROBE that tried to give a tenant its own course-approval workflow
-- with a state called 'draft', and was refused:
--
--   duplicate key value violates unique constraint "workflow_states_global_key"
--   DETAIL:  Key (key)=(draft) already exists.
--
-- THE TWO OFFENDERS:
--
--   workflow_states_global_key   unique (key) where organization_id is null
--   workflow_states_org_key      unique (organization_id, key) where organization_id is not null
--
-- Between them they said a state key may appear ONCE PER ORGANISATION across the
-- whole platform. Under the old design that was coherent, because an
-- organisation had exactly one workflow. Under the builder it is fatal: a course
-- approval and a proposal approval both want a state called 'draft', and the
-- second one is refused by an index.
--
-- THIS IS WHERE THE LIMITATION ACTUALLY LIVED. Not in the application, not in
-- the table shape, not in anybody's design document — in two partial unique
-- indexes that nobody would think to look at. Worth remembering the next time a
-- constraint looks like a modelling decision: sometimes it is the modelling
-- decision, and the model is only a description of it.
--
-- workflow_states_version_key_uniq (migration 323) already states the rule that
-- was always meant: a state key is unique WITHIN A WORKFLOW VERSION. Two
-- workflows may each have a 'draft'; one workflow may not have two.
-- ============================================================================

drop index if exists workflow_states_global_key;
drop index if exists workflow_states_org_key;

-- Redundant now, and it is a CONSTRAINT rather than a bare index so it has to be
-- dropped as one — dropping the index directly is refused with 2BP01.
-- from_state_id determines the version, so workflow_transitions_version_action_uniq
-- says the same thing and says it in terms of the version, which is the unit
-- that matters.
alter table workflow_transitions
    drop constraint if exists workflow_transitions_from_state_id_action_key;

comment on index workflow_states_version_key_uniq is
    'A state key is unique within a workflow version. Replaces workflow_states_global_key and workflow_states_org_key (dropped in 326), which allowed a key only once per organisation and therefore allowed an organisation only one workflow.';
