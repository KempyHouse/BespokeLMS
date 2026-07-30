-- 283: a notification domain for the commercial side of the house.
--
-- notification_domain covered auth, account, tenant_admin, infrastructure,
-- enrolment, progress, certification, content, workflow, digest and website --
-- everything except selling. Proposal engagement and contract renewals both
-- need somewhere to live, and filing them under 'workflow' would have made
-- the domain filter useless for the people who care about either.
--
-- SEPARATE MIGRATION ON PURPOSE. Postgres will not let a new enum value be
-- USED in the same transaction that adds it, so the events that reference
-- 'sales' are seeded in 286 rather than here.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170354).

alter type public.notification_domain add value if not exists 'sales';
