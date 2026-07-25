-- 053_bespokelms_notification_events_seed.sql
--
-- The P0 event registry: the fourteen notifications that have to work before
-- the first real client tenant is onboarded.
--
-- Two decisions are worth reading before adding to this list.
--
-- Cadence is not enumerated. `training_due` is one event whose reminder ladder
-- lives in notification_schedules as signed day offsets, so it covers the
-- fourteen-days-out warning, the due-today notice and the overdue chase from a
-- single template. The alternative — one catalogue entry per offset — is what
-- takes a catalogue from fourteen entries to sixty without adding a single new
-- thing the platform can say.
--
-- suppression_class is the compliance surface. non_suppressible events cannot
-- be switched off anywhere; a learner who could mute "your password changed"
-- has muted their own breach alarm, and one who could mute a forced
-- recertification notice has muted their employer's legal obligation. The
-- guard is the trigger in 050, not a code path.
--
-- Research: docs/BespokeLMS-System-Emails-Research.md sections 3 and 7.

insert into notification_events
  (key, name, description, domain, suppression_class, tier, recipient_roles, channels, content_tier, source_note, is_scheduled, is_active)
values
  ('forgot_password', 'Forgot password',
   'Someone asked to reset the password on an account. Sent only where the address matches an account; the on-screen response is identical either way.',
   'auth', 'non_suppressible', 'p0', '{}', '{email}', 't1_operational',
   'Supabase GoTrue recovery', false, true),

  ('password_changed', 'Password changed',
   'A password was changed, whether by the account holder, an administrator, or the completion of a reset. Carries no token.',
   'auth', 'non_suppressible', 'p0', '{}', '{email}', 't1_operational',
   'Supabase GoTrue password_changed_notification', false, true),

  ('email_change_confirm', 'Confirm new email address',
   'Sent to the proposed new address to prove the recipient controls it.',
   'auth', 'non_suppressible', 'p0', '{}', '{email}', 't1_operational',
   'Supabase GoTrue email_change, new address', false, true),

  ('email_change_notify', 'Email address change requested',
   'Sent to the address of record when a change is requested. The single highest-value anti-takeover message the platform sends.',
   'auth', 'non_suppressible', 'p0', '{}', '{email}', 't1_operational',
   'Supabase GoTrue email_change, old address', false, true),

  ('account_invited', 'Invitation to join',
   'An administrator has invited someone to a tenant. Names the inviter, the tenant and the role, because specificity is the anti-phishing control. Carries the privacy notice required at first communication.',
   'account', 'non_suppressible', 'p0', '{}', '{email}', 't1_operational',
   'invitations insert', false, true),

  ('role_changed', 'Access changed',
   'A profile role was changed. A privilege change is a security event and is notified regardless of preference.',
   'account', 'non_suppressible', 'p0', '{}', '{email,notification}', 't1_operational',
   'profiles.role update', false, true),

  ('sending_domain_broken', 'Sending domain failing',
   'A tenant sending domain no longer authenticates. Every other email to that tenant is silently failing until it is fixed.',
   'infrastructure', 'non_suppressible', 'p0', '{bespokelms_owner,lms_operator_admin}', '{email,notification}', 't1_operational',
   'tenant_email_aliases re-check failure', false, true),

  ('enrollment_assigned', 'Course assigned',
   'A course was assigned to a learner by an administrator or by a rule.',
   'enrolment', 'org_optional', 'p0', '{}', '{email,notification}', 't1_operational',
   'enrollments insert where source in (auto, manual)', false, true),

  ('training_due', 'Training due',
   'One template covering the whole due-date ladder. The signed offsets in notification_schedules decide whether a given send is a warning, a due-today notice or an overdue chase.',
   'progress', 'org_optional', 'p0', '{}', '{email,notification}', 't1_operational',
   'enrollments.due_at', true, true),

  ('course_completed', 'Course completed',
   'A learner finished a course. Carries no recommendations: a completion notice that promotes another course becomes direct marketing in its entirety.',
   'progress', 'preference', 'p0', '{}', '{email,notification}', 't1_operational',
   'enrollments.completed_at', false, true),

  ('certificate_issued', 'Certificate issued',
   'A certificate was issued. Links to an authenticated download rather than attaching the file.',
   'certification', 'preference', 'p0', '{}', '{email,notification}', 't1_operational',
   'certificates.issued_at', false, true),

  ('certificate_expiring', 'Certificate expiring',
   'Advance warning that a certificate lapses. Laddered at 90, 30 and 7 days by default.',
   'certification', 'org_optional', 'p0', '{}', '{email,notification}', 't1_operational',
   'certificates.expires_at', true, true),

  ('certificate_expired', 'Certificate expired',
   'A certificate has lapsed and the holder is no longer certified.',
   'certification', 'org_optional', 'p0', '{}', '{email,notification}', 't1_operational',
   'certificates.expires_at passed', true, true),

  ('course_now_available', 'Course now available',
   'A course the learner explicitly asked to be told about has moved from coming soon to published. Transactional because the recipient requested it; carries no other catalogue content.',
   'content', 'preference', 'p0', '{}', '{email}', 't1_operational',
   'course_notify_requests plus courses.catalog_status coming_soon to published', false, true);

-- Platform default reminder ladders. A tenant that wants its own inserts rows
-- with its organization_id and those win; absent tenant rows, these apply.
--
-- The overdue rung repeats weekly and stops at ninety days. An uncapped
-- recurrence is how a compliance reminder turns into the thing a learner marks
-- as spam, and a spam complaint costs every tenant on the sending domain.
insert into notification_schedules (event_key, organization_id, offset_days, repeat_every_days, repeat_until_days, sort)
values
  ('training_due', null, -14, null, null, 10),
  ('training_due', null,  -7, null, null, 20),
  ('training_due', null,  -2, null, null, 30),
  ('training_due', null,  -1, null, null, 40),
  ('training_due', null,   0, null, null, 50),
  ('training_due', null,   1,    7,   90, 60),

  ('certificate_expiring', null, -90, null, null, 10),
  ('certificate_expiring', null, -30, null, null, 20),
  ('certificate_expiring', null,  -7, null, null, 30),

  ('certificate_expired', null, 0, null, null, 10);

-- forgot_password predates the registry: attach it, lock its classification,
-- and give it the plain-text part every other template now ships with.
update outbound_templates
   set event_key = 'forgot_password',
       is_classification_locked = true,
       locale = 'en-GB',
       body_text = 'Hi {{user_name}}

We received a request to reset the password for your {{app_name}} account. Choose a new one by opening this link:

{{reset_url}}

For your security, this link expires in {{expires_in}} and can only be used once.

Did not request this? You can safely ignore this email and your password will stay the same.

Need a hand? Contact {{support_email}}.'
 where key = 'forgot_password'
   and organization_id is null;
