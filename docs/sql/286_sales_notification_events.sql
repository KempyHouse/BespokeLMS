-- 286: notification events for the commercial layer.
--
-- Engagement events are preference-suppressible and go to the notification
-- channel only. They are deliberately NOT emailed: an alert that a prospect
-- opened a proposal is useful the moment you are at your desk and noise at
-- every other moment.
--
-- Only engagement at or above the tenant's configured confidence raises one at
-- all (see email_engagement_settings.notify_min_confidence, default
-- 'confirmed'), so a mail scanner never prompts a phone call.
--
-- The two contract events are scheduled, which means they depend on the
-- Laravel Cloud scheduler worker. As at this migration no scheduled command
-- has ever run in production -- see bug 2cf06b8e.
--
-- Depends on 283 for the 'sales' domain: Postgres will not let a new enum
-- value be used in the same transaction that adds it.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170537).

insert into public.notification_events
    (key, name, description, domain, category, suppression_class, tier,
     recipient_roles, channels, content_tier, is_scheduled, is_active, source_note)
values
    ('proposal_opened',
     'Proposal: opened by the recipient',
     'A named recipient opened a proposal email. Raised only at or above the tenant''s configured confidence threshold, so scanner and prefetch activity is never notified.',
     'sales', 'transactional', 'preference', 'p2',
     '{}', '{notification}', 't1_operational', false, true,
     'Seeded with the quote-to-contract epic. Requires email_engagement_settings.notify_on_engagement.'),

    ('proposal_link_clicked',
     'Proposal: link clicked',
     'A named recipient followed a tracked link in a proposal email. Carries which link, so a click on the pricing section reads differently from a click on the footer.',
     'sales', 'transactional', 'preference', 'p2',
     '{}', '{notification}', 't1_operational', false, true,
     'Seeded with the quote-to-contract epic. Requires email_engagement_settings.notify_on_engagement.'),

    ('contract_renewal_notice_due',
     'Contract: notice deadline approaching',
     'The last date to serve notice and prevent automatic renewal is approaching. Scheduled from contracts.notice_deadline_on.',
     'sales', 'transactional', 'org_optional', 'p1',
     '{}', '{email,notification}', 't1_operational', true, true,
     'Seeded with the quote-to-contract epic. Depends on the Laravel Cloud scheduler worker being enabled.'),

    ('contract_usage_measurement_due',
     'Contract: usage measurement due',
     'A measurement period has closed on a usage commitment and the chargeable quantity needs recording. Scheduled from the commitment measurement frequency.',
     'sales', 'transactional', 'org_optional', 'p1',
     '{}', '{email,notification}', 't1_operational', true, true,
     'Seeded with the quote-to-contract epic. Depends on the Laravel Cloud scheduler worker being enabled.')
on conflict (key) do nothing;
