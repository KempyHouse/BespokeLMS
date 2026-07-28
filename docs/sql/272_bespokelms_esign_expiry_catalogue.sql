-- 272: Proposals & e-signature — expiry notification and the first catalogue
-- template.
--
-- Two small closures of Sprint 5 gaps. First, the expiry sweep
-- (esign:send-reminders, scheduled daily) needs an event to speak through
-- when an envelope lapses: esign_document_expired, sender-facing,
-- non-suppressible (a lapsed agreement is not chatter).
--
-- Second, the platform template catalogue gains its first row: a SaaS
-- agreement skeleton modelled on the structure of the executed Turner Price
-- agreement (definitions, scope, SLA, data protection, liability, fees,
-- term, signatures) with merge fields resolved from the CRM at compose time.
-- owning_organization_id null = platform catalogue; tenants clone on use and
-- edit their copy, exactly as catalogue pathways behave.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 272_bespokelms_esign_expiry_catalogue.

insert into notification_events
  (key, name, description, domain, category, suppression_class, tier, recipient_roles, channels, content_tier, source_note, is_scheduled, is_active)
select 'esign_document_expired', 'E-sign: document expired',
       'An envelope passed its expiry date unsigned. Sender-facing; outstanding signing links are invalidated.',
       'workflow'::notification_domain, 'transactional'::outbound_category,
       'non_suppressible'::notification_suppression_class, 'p1'::notification_tier,
       '{}', '{email,notification}'::text[]::outbound_channel[], 't1_operational'::email_content_tier,
       'Seeded by migration 272 (esign module).', false, true
where not exists (select 1 from notification_events e where e.key = 'esign_document_expired');

insert into outbound_templates
  (key, name, channel, category, event_key, subject, body_html, body_text, variables, locale, is_protected, is_active, organization_id)
select 'esign_document_expired', 'E-sign document expired',
       'email'::outbound_channel, 'transactional'::outbound_category, 'esign_document_expired',
       'Expired unsigned: {{document_title}}',
       '<p>Hello {{recipient_name}},</p><p><strong>{{document_title}}</strong> reached its expiry date without all signatures being completed. The outstanding signing links have been invalidated.</p><p>You can issue a new version from the document page if the agreement is still wanted.</p>',
       'Hello {{recipient_name}}, {{document_title}} reached its expiry date without all signatures being completed. The outstanding signing links have been invalidated. You can issue a new version from the document page if the agreement is still wanted.',
       '["recipient_name","document_title"]'::jsonb,
       'en-GB', true, true, null
where not exists (select 1 from outbound_templates t
                  where t.key = 'esign_document_expired' and t.organization_id is null and t.locale = 'en-GB');

insert into esign_templates (owning_organization_id, name, description, body_html, merge_manifest, is_active)
select null,
       'SaaS agreement (white-label platform)',
       'A software-as-a-service agreement skeleton modelled on the structure of an executed BespokeLMS white-label agreement: parties, recitals, scope, SLA, data protection, liability, fees, term and signature blocks. Review every clause with your own legal advice before use.',
       '<h1>Software as a Service Agreement</h1>'
       || '<p>This agreement is entered into on {{deal.close_date}} between <strong>{{organisation.name}}</strong> ("Provider") and <strong>{{account.name}}</strong> ("Client"), whose primary contact is {{contact.first_name}} {{contact.last_name}} ({{contact.email}}).</p>'
       || '<h2>1. Definitions and interpretation</h2><p>Defined terms used in this agreement are set out in this clause. [Complete the definitions relevant to your service.]</p>'
       || '<h2>2. Scope of services</h2><p>The Provider agrees to provide the Client with access to the platform and the services described in this clause. [Describe the modules, content and support included.]</p>'
       || '<h2>3. Service levels</h2><p>The Provider will use commercially reasonable efforts to meet the availability and support response targets set out in this clause. [State the uptime target, support hours and response times.]</p>'
       || '<h2>4. Data protection</h2><p>Both parties will comply with applicable data protection legislation, including the UK GDPR and the Data Protection Act 2018. The Provider acts as processor and the Client as controller of Client data. [Reference or incorporate your data processing agreement.]</p>'
       || '<h2>5. Limitation of liability</h2><p>[State exclusions and the liability cap.]</p>'
       || '<h2>6. Fees and payment</h2><p>The Client agrees to pay the fees set out in this clause for the deal <strong>{{deal.name}}</strong>. [State the fee structure, invoicing frequency and payment terms.]</p>'
       || '<h2>7. Term and termination</h2><p>[State the initial term, renewal, and termination rights.]</p>'
       || '<h2>8. Signatures</h2><p>Signed for and on behalf of each party by its authorised signatories, electronically, on the dates recorded in the evidence trail attached to this document.</p>',
       '["organisation.name","account.name","contact.first_name","contact.last_name","contact.email","deal.name","deal.close_date"]'::jsonb,
       true
where not exists (select 1 from esign_templates where owning_organization_id is null and name = 'SaaS agreement (white-label platform)');
