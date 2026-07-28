-- 271: Proposals & e-signature — notification events and outbound templates.
--
-- One row per automatic notification the esign flow can produce, plus a
-- protected platform-level email template for each (en-GB; tenants may add
-- their own overrides in the outbound console; resolution is nearest scope
-- wins, then locale). Producers call the dispatcher with these event keys —
-- App\Support\Notifications\NotificationDispatcher decides suppression,
-- template and logging.
--
-- Domain: 'workflow' — the notification_domain enum has no crm/esign label
-- and the approval/signature loop is a workflow in the existing sense.
-- Adding a dedicated 'esign' label is deliberately avoided here so the enum
-- change (unsafe in the same transaction as its first use) never blocks this
-- seed.
--
-- Suppression: the signing invitation, OTP and decline/complete confirmations
-- are transactional and non-suppressible (they ARE the product working);
-- viewed/reminder chatter respects preferences.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 271_bespokelms_esign_notifications.

insert into notification_events
  (key, name, description, domain, category, suppression_class, tier, recipient_roles, channels, content_tier, source_note, is_scheduled, is_active)
select v.key, v.name, v.description,
       'workflow'::notification_domain, 'transactional'::outbound_category,
       v.suppression::notification_suppression_class, v.tier::notification_tier,
       '{}', v.channels::text[]::outbound_channel[], 't1_operational'::email_content_tier,
       'Seeded by migration 271 (esign module).', false, true
from (values
  ('esign_approval_requested', 'E-sign: approval requested',
   'A co-author''s approval is requested on a draft envelope.',
   'non_suppressible', 'p1', '{email,notification}'),
  ('esign_document_sent', 'E-sign: document sent for signature',
   'The signing invitation to an external recipient, carrying the single-use signing link.',
   'non_suppressible', 'p0', '{email}'),
  ('esign_otp_code', 'E-sign: one-time passcode',
   'The OTP step-up code for a signer on a document that requires it.',
   'non_suppressible', 'p0', '{email}'),
  ('esign_document_viewed', 'E-sign: document viewed',
   'A recipient opened the document. Sender-facing progress chatter.',
   'preference', 'p2', '{notification}'),
  ('esign_document_signed', 'E-sign: document signed',
   'A signer completed their signature. Sender-facing.',
   'non_suppressible', 'p1', '{email,notification}'),
  ('esign_document_declined', 'E-sign: document declined',
   'A signer declined, with their reason. Sender-facing.',
   'non_suppressible', 'p1', '{email,notification}'),
  ('esign_document_completed', 'E-sign: document completed',
   'All signers have signed; the executed copy and certificate are filed. Sent to the sender and all parties.',
   'non_suppressible', 'p1', '{email}')
) as v(key, name, description, suppression, tier, channels)
where not exists (select 1 from notification_events e where e.key = v.key);

insert into outbound_templates
  (key, name, channel, category, event_key, subject, body_html, body_text, variables, locale, is_protected, is_active, organization_id)
select v.key, v.name, 'email'::outbound_channel, 'transactional'::outbound_category, v.key,
       v.subject, v.body_html, v.body_text, v.variables::jsonb, 'en-GB', true, true, null
from (values
  ('esign_approval_requested', 'E-sign approval requested',
   '{{sender_name}} has requested your approval: {{document_title}}',
   '<p>Hello {{recipient_name}},</p><p>{{sender_name}} has asked you to review and approve <strong>{{document_title}}</strong> before it is sent for signature.</p><p><a href="{{action_url}}">Review and approve the document</a></p><p>Approval is recorded against version {{version_no}}. If a newer version is created, you will be asked again.</p>',
   'Hello {{recipient_name}}, {{sender_name}} has asked you to review and approve {{document_title}} before it is sent for signature. Review it here: {{action_url}}',
   '["recipient_name","sender_name","document_title","action_url","version_no"]'),
  ('esign_document_sent', 'E-sign signing invitation',
   '{{sender_org}} has sent you a document to sign: {{document_title}}',
   '<p>Hello {{recipient_name}},</p><p>{{sender_name}} of {{sender_org}} has sent you <strong>{{document_title}}</strong> to review and sign electronically.</p><p><a href="{{action_url}}">Review and sign the document</a></p><p>This link is unique to you — please do not forward it. It expires on {{expires_on}}.</p>',
   'Hello {{recipient_name}}, {{sender_name}} of {{sender_org}} has sent you {{document_title}} to review and sign electronically. Review and sign here: {{action_url}} — this link is unique to you and expires on {{expires_on}}.',
   '["recipient_name","sender_name","sender_org","document_title","action_url","expires_on"]'),
  ('esign_otp_code', 'E-sign one-time passcode',
   'Your verification code for {{document_title}}',
   '<p>Hello {{recipient_name}},</p><p>Your verification code for <strong>{{document_title}}</strong> is:</p><p><strong>{{otp_code}}</strong></p><p>The code expires in {{otp_minutes}} minutes. If you did not request it, you can ignore this email.</p>',
   'Your verification code for {{document_title}} is {{otp_code}}. It expires in {{otp_minutes}} minutes.',
   '["recipient_name","document_title","otp_code","otp_minutes"]'),
  ('esign_document_viewed', 'E-sign document viewed',
   '{{recipient_name}} viewed {{document_title}}',
   '<p>{{recipient_name}} has viewed <strong>{{document_title}}</strong>.</p>',
   '{{recipient_name}} has viewed {{document_title}}.',
   '["recipient_name","document_title"]'),
  ('esign_document_signed', 'E-sign document signed',
   '{{recipient_name}} signed {{document_title}}',
   '<p>{{recipient_name}} has signed <strong>{{document_title}}</strong>.</p><p><a href="{{action_url}}">View the document status</a></p>',
   '{{recipient_name}} has signed {{document_title}}. Status: {{action_url}}',
   '["recipient_name","document_title","action_url"]'),
  ('esign_document_declined', 'E-sign document declined',
   '{{recipient_name}} declined {{document_title}}',
   '<p>{{recipient_name}} has declined <strong>{{document_title}}</strong>.</p><p>Reason given: {{declined_reason}}</p><p><a href="{{action_url}}">View the document</a></p>',
   '{{recipient_name}} has declined {{document_title}}. Reason: {{declined_reason}}. View: {{action_url}}',
   '["recipient_name","document_title","declined_reason","action_url"]'),
  ('esign_document_completed', 'E-sign document completed',
   'Completed: {{document_title}}',
   '<p>Hello {{recipient_name}},</p><p><strong>{{document_title}}</strong> has been signed by all parties and is now complete.</p><p>The executed copy and its certificate of completion have been filed. Document fingerprint (SHA-256): {{sha256}}</p>',
   'Hello {{recipient_name}}, {{document_title}} has been signed by all parties and is now complete. Document fingerprint (SHA-256): {{sha256}}',
   '["recipient_name","document_title","sha256"]')
) as v(key, name, subject, body_html, body_text, variables)
where not exists (select 1 from outbound_templates t where t.key = v.key and t.organization_id is null and t.locale = 'en-GB');
