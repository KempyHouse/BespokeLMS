-- 050_bespokelms_notification_registry.sql
--
-- The event registry behind System Emails.
--
-- One event is declared once and fans out to channels, so the in-app
-- notifications table and the email catalogue never drift apart. Cadence
-- lives in notification_schedules as signed day offsets rather than as one
-- template per reminder, which is what keeps "training due" a single
-- template instead of six.
--
-- Preferences resolve user -> organisation -> platform -> event default, and
-- an organisation-level row may be locked so a learner cannot switch off a
-- compliance warning. Events classed non_suppressible cannot be disabled at
-- any level; the guard is a trigger, not a convention.
--
-- Research: docs/BespokeLMS-System-Emails-Research.md sections 1, 2 and 6.

-- ---------------------------------------------------------------------------
-- enums
-- ---------------------------------------------------------------------------

create type notification_domain as enum (
  'auth',
  'account',
  'tenant_admin',
  'infrastructure',
  'enrolment',
  'progress',
  'certification',
  'content',
  'workflow',
  'digest',
  'website'
);

-- non_suppressible : security or compliance critical, no opt-out at any level
-- org_optional     : the learner cannot opt out, the tenant admin may disable
-- preference       : freely preference-controlled
create type notification_suppression_class as enum (
  'non_suppressible',
  'org_optional',
  'preference'
);

create type notification_tier as enum ('p0', 'p1', 'p2');

-- How much of the learning record may appear in the message body.
-- t0 carries no course detail at all; t2 may carry scores. Default is t1
-- because tenants configure their own catalogues, so we cannot know at build
-- time which course titles amount to health data.
create type email_content_tier as enum ('t0_opaque', 't1_operational', 't2_full');

-- ---------------------------------------------------------------------------
-- notification_events -- the registry. Platform-owned; tenants do not add rows.
-- ---------------------------------------------------------------------------

create table notification_events (
  key                text primary key,
  name               text not null,
  description        text,
  domain             notification_domain not null,
  category           outbound_category not null default 'transactional',
  suppression_class  notification_suppression_class not null,
  tier               notification_tier not null default 'p1',
  -- Roles that may receive this event. Empty means "the subject of the event",
  -- resolved by the dispatcher rather than by role.
  recipient_roles    app_role[] not null default '{}',
  channels           outbound_channel[] not null default '{email}',
  content_tier       email_content_tier not null default 't1_operational',
  -- The table or column that fires it, so the registry stays honest about
  -- which events have a real source and which are still waiting on schema.
  source_note        text,
  -- Whether the anchor for notification_schedules is a date in the future
  -- (due_at, expires_at) or the moment the event happened.
  is_scheduled       boolean not null default false,
  is_active          boolean not null default false,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint notification_events_key_format
    check (key ~ '^[a-z][a-z0-9_]*$'),
  constraint notification_events_channels_not_empty
    check (array_length(channels, 1) >= 1),
  -- Marketing may never be declared here. This registry is the transactional
  -- and system plane; mixing the two is what makes a service message into
  -- direct marketing under PECR reg 22.
  constraint notification_events_not_marketing
    check (category <> 'marketing')
);

comment on table notification_events is
  'Registry of every automatic platform notification. One row per event, fanned out to channels by the dispatcher.';
comment on column notification_events.suppression_class is
  'non_suppressible = no opt-out anywhere (security/compliance); org_optional = tenant admin may disable, learner may not; preference = freely controlled.';
comment on column notification_events.content_tier is
  'Ceiling on how much learning detail the rendered body may carry. t1 is the safe default.';

create index notification_events_domain_idx on notification_events (domain, tier);
create index notification_events_active_idx on notification_events (is_active) where is_active;

-- ---------------------------------------------------------------------------
-- notification_schedules -- the cadence ladder
-- ---------------------------------------------------------------------------
-- offset_days is signed against the event's anchor date: negative fires
-- before (a due-date warning), zero on the day, positive after (an overdue
-- nudge). One "training_due" template therefore covers -14, -7, -1, 0, +1
-- and +7 rather than six near-identical templates.

create table notification_schedules (
  id                 uuid primary key default gen_random_uuid(),
  event_key          text not null references notification_events (key) on delete cascade,
  -- null = the platform default ladder, inherited by every tenant that has
  -- not defined its own.
  organization_id    uuid references organizations (id) on delete cascade,
  offset_days        integer not null,
  -- Repeat this rung every N days until the learner acts, with a hard stop.
  -- Absorb caps its recurring overdue nudge at six months; an uncapped
  -- recurrence is how a compliance reminder becomes harassment.
  repeat_every_days  integer,
  repeat_until_days  integer,
  send_at_local_time time not null default '09:00',
  is_active          boolean not null default true,
  sort               integer not null default 0,
  created_by         uuid references profiles (id) on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint notification_schedules_offset_sane
    check (offset_days between -365 and 365),
  constraint notification_schedules_repeat_positive
    check (repeat_every_days is null or repeat_every_days > 0),
  constraint notification_schedules_repeat_needs_stop
    check (repeat_every_days is null or repeat_until_days is not null),
  constraint notification_schedules_stop_after_start
    check (repeat_until_days is null or repeat_until_days > offset_days)
);

comment on column notification_schedules.offset_days is
  'Signed days against the event anchor. Negative = before, 0 = on the day, positive = after.';
comment on column notification_schedules.repeat_until_days is
  'Hard stop for a recurring nudge, as an offset from the anchor. Required whenever repeat_every_days is set.';

-- Nullable organization_id cannot participate in a plain unique constraint,
-- so the platform default and the tenant override each get their own index.
create unique index notification_schedules_platform_uniq
  on notification_schedules (event_key, offset_days)
  where organization_id is null;

create unique index notification_schedules_tenant_uniq
  on notification_schedules (event_key, organization_id, offset_days)
  where organization_id is not null;

create index notification_schedules_lookup_idx
  on notification_schedules (event_key, organization_id)
  where is_active;

-- ---------------------------------------------------------------------------
-- notification_preferences
-- ---------------------------------------------------------------------------
-- Three scopes in one table:
--   organization_id null, profile_id null -> platform default
--   organization_id set,  profile_id null -> tenant default (lockable)
--   organization_id set,  profile_id set  -> the individual's choice
-- Resolution is most specific wins, unless a broader row is locked.

create table notification_preferences (
  id               uuid primary key default gen_random_uuid(),
  event_key        text not null references notification_events (key) on delete cascade,
  organization_id  uuid references organizations (id) on delete cascade,
  profile_id       uuid references profiles (id) on delete cascade,
  channel          outbound_channel not null default 'email',
  is_enabled       boolean not null default true,
  -- Moodle's MESSAGE_FORCED, which compliance tenants need: the admin sets
  -- the value and the learner cannot change it.
  is_locked        boolean not null default false,
  updated_by       uuid references profiles (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- A personal preference always belongs to a tenant.
  constraint notification_preferences_profile_needs_org
    check (profile_id is null or organization_id is not null),
  -- Only a default row can lock anything. A learner cannot lock themselves in.
  constraint notification_preferences_lock_is_a_default
    check (not is_locked or profile_id is null)
);

create unique index notification_preferences_platform_uniq
  on notification_preferences (event_key, channel)
  where organization_id is null and profile_id is null;

create unique index notification_preferences_org_uniq
  on notification_preferences (event_key, organization_id, channel)
  where organization_id is not null and profile_id is null;

create unique index notification_preferences_profile_uniq
  on notification_preferences (event_key, profile_id, channel)
  where profile_id is not null;

create index notification_preferences_profile_idx
  on notification_preferences (profile_id) where profile_id is not null;

-- ---------------------------------------------------------------------------
-- Guard: a non-suppressible event cannot be switched off, anywhere.
-- ---------------------------------------------------------------------------
-- Password-changed notices and forced recertification notices are the user's
-- own detection mechanism. Making this a constraint rather than a code path
-- means a future admin screen cannot quietly bypass it.

create or replace function notification_preference_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ev_class notification_suppression_class;
begin
  select suppression_class into ev_class
  from notification_events
  where key = new.event_key;

  if ev_class = 'non_suppressible' and new.is_enabled = false then
    raise exception
      'notification event % is non-suppressible and cannot be disabled', new.event_key
      using errcode = 'check_violation';
  end if;

  if ev_class = 'org_optional'
     and new.is_enabled = false
     and new.profile_id is not null then
    raise exception
      'notification event % may only be disabled by the organisation, not by an individual', new.event_key
      using errcode = 'check_violation';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger notification_preferences_guard
  before insert or update on notification_preferences
  for each row execute function notification_preference_guard();

-- ---------------------------------------------------------------------------
-- outbound_templates: the columns the catalogue needs
-- ---------------------------------------------------------------------------

alter table outbound_templates
  add column event_key text references notification_events (key) on delete set null,
  -- The plain-text alternative. RFC 2046 orders multipart alternatives by
  -- increasing fidelity, so this part is transmitted FIRST and the HTML last.
  -- It must carry the whole message: an agent that selects the text part and
  -- finds "view this email in your browser" has received nothing, which for a
  -- deadline notice is a failure to provide the information in an accessible
  -- format.
  add column body_text text,
  add column locale text not null default 'en-GB',
  -- Once locked, category cannot move between system/transactional and
  -- marketing. See the trigger below.
  add column is_classification_locked boolean not null default false;

comment on column outbound_templates.body_text is
  'Plain-text alternative, generated from the content model rather than by stripping the HTML. Transmitted first in the multipart body.';
comment on column outbound_templates.locale is
  'BCP-47 tag. Fallback order: this locale -> tenant default -> platform default -> en-GB.';

create index outbound_templates_event_idx on outbound_templates (event_key, channel, locale);

-- One template per event, channel and locale within a scope.
create unique index outbound_templates_platform_key_uniq
  on outbound_templates (key, channel, locale)
  where organization_id is null;

create unique index outbound_templates_tenant_key_uniq
  on outbound_templates (organization_id, key, channel, locale)
  where organization_id is not null;

-- ---------------------------------------------------------------------------
-- Guard: classification is set at design time, not at runtime.
-- ---------------------------------------------------------------------------
-- The ICO's position is that a service message carrying any direct-marketing
-- element counts as direct marketing in its entirety. A runtime flag guarding
-- that boundary is precisely the failure mode behind the EE and American
-- Express penalties, so a locked template's category is immutable.

create or replace function outbound_template_classification_guard()
returns trigger
language plpgsql
as $$
begin
  if old.is_classification_locked
     and new.category is distinct from old.category then
    raise exception
      'template % has a locked classification (%) and cannot be reclassified',
      old.key, old.category
      using errcode = 'check_violation';
  end if;

  if old.is_classification_locked
     and new.is_classification_locked = false
     and old.is_protected then
    raise exception
      'template % is protected; its classification lock cannot be released', old.key
      using errcode = 'check_violation';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger outbound_templates_classification_guard
  before update on outbound_templates
  for each row execute function outbound_template_classification_guard();

-- ---------------------------------------------------------------------------
-- organizations: the content tier this tenant's emails may carry
-- ---------------------------------------------------------------------------

alter table organizations
  add column email_content_tier email_content_tier not null default 't1_operational';

comment on column organizations.email_content_tier is
  'Ceiling on learning detail in this tenant''s email bodies. Raising it to t2_full is an explicit, audited choice.';

-- courses: the flag that forces t0 regardless of the tenant setting
alter table courses
  add column is_sensitive boolean not null default false;

comment on column courses.is_sensitive is
  'Course whose title alone could reveal health, disciplinary or other special-category information. Forces t0_opaque email bodies whatever the tenant tier.';

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table notification_events enable row level security;
alter table notification_schedules enable row level security;
alter table notification_preferences enable row level security;

-- The registry is readable by any signed-in user, because the preference
-- screen has to name the events. Only the platform owner writes it.
create policy notification_events_read on notification_events
  for select to authenticated
  using (true);

create policy notification_events_write on notification_events
  for all to authenticated
  using (is_platform_owner())
  with check (is_platform_owner());

-- Platform defaults are readable by everyone, tenant rows by that tenant.
create policy notification_schedules_read on notification_schedules
  for select to authenticated
  using (
    organization_id is null
    or organization_id in (select org_and_descendants(auth_org_id()))
  );

create policy notification_schedules_write on notification_schedules
  for all to authenticated
  using (
    (organization_id is null and is_platform_owner())
    or (organization_id is not null
        and is_admin()
        and organization_id in (select org_and_descendants(auth_org_id())))
  )
  with check (
    (organization_id is null and is_platform_owner())
    or (organization_id is not null
        and is_admin()
        and organization_id in (select org_and_descendants(auth_org_id())))
  );

-- A learner sees the defaults that apply to them plus their own row.
create policy notification_preferences_read on notification_preferences
  for select to authenticated
  using (
    profile_id = my_profile_id()
    or organization_id is null
    or organization_id in (select org_and_descendants(auth_org_id()))
  );

-- A learner writes only their own row, and only where no broader row is
-- locked against the same event and channel.
create policy notification_preferences_write_own on notification_preferences
  for all to authenticated
  using (profile_id = my_profile_id())
  with check (
    profile_id = my_profile_id()
    and not exists (
      select 1
      from notification_preferences locked
      where locked.event_key = notification_preferences.event_key
        and locked.channel = notification_preferences.channel
        and locked.is_locked
        and locked.profile_id is null
        and (locked.organization_id is null
             or locked.organization_id = notification_preferences.organization_id)
    )
  );

create policy notification_preferences_write_admin on notification_preferences
  for all to authenticated
  using (
    (organization_id is null and is_platform_owner())
    or (organization_id is not null
        and is_admin()
        and organization_id in (select org_and_descendants(auth_org_id())))
  )
  with check (
    (organization_id is null and is_platform_owner())
    or (organization_id is not null
        and is_admin()
        and organization_id in (select org_and_descendants(auth_org_id())))
  );
