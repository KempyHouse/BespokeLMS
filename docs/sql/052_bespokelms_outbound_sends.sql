-- 052_bespokelms_outbound_sends.sql
--
-- Splits "did we notify them" from "what did the message say".
--
-- Compliance tenants ask for six-year retention on training communications.
-- They are asking the first question, not the second: in a tribunal what
-- matters is that the learner was told, when, and whether it arrived. Keeping
-- six years of rendered bodies to answer that means keeping six years of course
-- titles and learner names, which is a large pile of personal data held for a
-- purpose it is not needed for.
--
-- So outbound_sends is content-free and long-lived; email_send_logs keeps the
-- merge parameters and is swept after thirty days. Exact wording is
-- reconstructed from the template plus its updated_at, not archived.
--
-- Research: docs/BespokeLMS-System-Emails-Research.md sections 4.5 and 6.4.

create type outbound_delivery_status as enum (
  'queued', 'sent', 'delivered', 'bounced', 'complained', 'failed', 'suppressed', 'skipped'
);

create table outbound_sends (
  id                   uuid primary key default gen_random_uuid(),
  organization_id      uuid references organizations (id) on delete set null,
  profile_id           uuid references profiles (id) on delete set null,
  recipient_hash       text,
  event_key            text references notification_events (key) on delete set null,
  template_id          uuid references outbound_templates (id) on delete set null,
  template_updated_at  timestamptz,
  channel              outbound_channel not null default 'email',
  locale               text,
  content_tier         email_content_tier,
  status               outbound_delivery_status not null default 'queued',
  provider             text,
  provider_message_id  text,
  error_code           text,
  queued_at            timestamptz not null default now(),
  sent_at              timestamptz,
  delivered_at         timestamptz,
  failed_at            timestamptz,
  created_at           timestamptz not null default now()
);

comment on table outbound_sends is
  'Content-free proof of notification. Answers "did we tell them, when, and did it arrive" without retaining what the message said. Retained for years; the content-bearing counterpart in email_send_logs is retained for days.';
comment on column outbound_sends.recipient_hash is
  'SHA-256 of the lower-cased recipient address. Lets a support query match an address without the address being stored here.';
comment on column outbound_sends.template_updated_at is
  'The template''s updated_at at send time, so the exact wording can be reconstructed from history rather than archived.';

create index outbound_sends_profile_idx on outbound_sends (profile_id, event_key, queued_at desc);
create index outbound_sends_org_idx on outbound_sends (organization_id, queued_at desc);
create index outbound_sends_status_idx on outbound_sends (status)
  where status in ('queued', 'bounced', 'complained', 'failed');
create index outbound_sends_provider_idx on outbound_sends (provider_message_id)
  where provider_message_id is not null;

alter table outbound_sends enable row level security;

-- A learner can see what the platform sent them. That is an access-request
-- answer they can self-serve, and it costs nothing because the table holds no
-- message content.
create policy outbound_sends_read on outbound_sends
  for select to authenticated
  using (
    profile_id = my_profile_id()
    or is_platform_owner()
    or (is_admin() and organization_id in (select org_and_descendants(auth_org_id())))
  );

alter table email_send_logs
  add column outbound_send_id uuid references outbound_sends (id) on delete set null,
  add column merge_params jsonb not null default '{}'::jsonb,
  add column purge_after timestamptz not null default (now() + interval '30 days');

comment on column email_send_logs.merge_params is
  'The substitutions used at render time. Personal data, so short-lived: this is the content-bearing half of the split and is swept at purge_after.';
comment on column email_send_logs.purge_after is
  'When the content-bearing fields on this row must be deleted. The matching outbound_sends row survives.';

create index email_send_logs_purge_idx on email_send_logs (purge_after);
create index email_send_logs_send_idx on email_send_logs (outbound_send_id);
