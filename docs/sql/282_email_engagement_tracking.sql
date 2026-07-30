-- 282: every open and every click, with the machine noise labelled.
--
-- WHY A PER-EVENT TABLE and not two timestamp columns: the requirement is
-- every occurrence with a date and time, not the first one.
--
-- WHY CONFIDENCE IS A FIRST-CLASS COLUMN. Corporate mail security -- Mimecast,
-- Proofpoint, Microsoft Defender -- fetches every image and pre-clicks every
-- link before the recipient ever sees the message. Recording those as opens
-- would time-stamp a security appliance's curiosity as a buying signal, and
-- somebody would ring a prospect off the back of it. The e-sign module already
-- refuses to record 'viewed' on a GET for exactly this reason (see the
-- signing controller); that precedent is honoured here rather than
-- contradicted.
--
-- PRIVACY. outbound_sends deliberately stores a HASH of the recipient rather
-- than the address, and content is tiered t0_opaque / t1_operational / t2_full.
-- Engagement tracking identifies a named individual, which cuts across that,
-- so it is off unless a tenant turns it on AND records a lawful basis -- the
-- constraint on email_engagement_settings enforces that, rather than trusting
-- anyone to remember.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170348).

create type public.email_engagement_event as enum ('opened', 'clicked');

-- confirmed  a human almost certainly did this
-- probable   consistent with a human, but not provable
-- machine    attributed to a scanner, prefetcher or bot; never notified on
create type public.email_engagement_confidence as enum ('confirmed', 'probable', 'machine');

-- Links are rewritten through our own redirect so click tracking works on the
-- plain SMTP transports too, and so a click ties to a link we named rather
-- than to a provider's opaque identifier.
create table public.outbound_tracked_links (
    id uuid primary key default gen_random_uuid(),
    outbound_send_id uuid not null references public.outbound_sends (id) on delete cascade,
    organization_id uuid references public.organizations (id) on delete cascade,
    token text not null unique,
    target_url text not null,
    label text,
    position integer not null default 0,
    created_at timestamptz not null default now()
);

comment on table public.outbound_tracked_links is
  'A link as rewritten into an outbound email. The token is what appears in the redirect url; target_url is where the person actually goes.';

create index outbound_tracked_links_send_idx on public.outbound_tracked_links (outbound_send_id);

create table public.email_engagement_events (
    id uuid primary key default gen_random_uuid(),
    organization_id uuid not null references public.organizations (id) on delete cascade,
    outbound_send_id uuid references public.outbound_sends (id) on delete set null,
    tracked_link_id uuid references public.outbound_tracked_links (id) on delete set null,
    esign_document_id uuid references public.esign_documents (id) on delete set null,
    contact_id uuid references public.crm_contacts (id) on delete set null,
    deal_id uuid references public.crm_deals (id) on delete set null,
    recipient_hash text,
    event public.email_engagement_event not null,
    confidence public.email_engagement_confidence not null default 'probable',
    machine_reason text,
    occurred_at timestamptz not null default now(),
    seconds_since_delivery integer,
    user_agent text,
    client_hint text,
    ip_hash text,
    country_code character(2),
    provider text,
    provider_event_id text,
    created_at timestamptz not null default now(),
    constraint email_engagement_machine_reason_present check (
        confidence <> 'machine' or machine_reason is not null
    ),
    constraint email_engagement_click_has_link check (
        event <> 'clicked' or tracked_link_id is not null
    )
);

comment on table public.email_engagement_events is
  'One row per open or click. Never deduplicated -- the requirement is every occurrence, with the date and time it happened.';
comment on column public.email_engagement_events.seconds_since_delivery is
  'Seconds between the send being delivered and this event. A near-zero value is the signature of a mail scanner, not a reader.';
comment on column public.email_engagement_events.machine_reason is
  'Why this was attributed to a machine: known scanner user agent, prefetch window, datacentre ip range, or head request.';

-- Idempotency for provider webhook redelivery. Providers retry, and a retry
-- must not read as a second open.
create unique index email_engagement_provider_event_idx
    on public.email_engagement_events (provider, provider_event_id)
    where provider_event_id is not null;

create index email_engagement_org_time_idx on public.email_engagement_events (organization_id, occurred_at desc);
create index email_engagement_send_idx on public.email_engagement_events (outbound_send_id, occurred_at desc);
create index email_engagement_document_idx on public.email_engagement_events (esign_document_id, occurred_at desc)
    where esign_document_id is not null;
create index email_engagement_deal_idx on public.email_engagement_events (deal_id, occurred_at desc)
    where deal_id is not null;

-- Per-tenant switch. Off by default, and it cannot be turned on without
-- recording why the tenant believes it may do this.
create table public.email_engagement_settings (
    organization_id uuid primary key references public.organizations (id) on delete cascade,
    track_opens boolean not null default false,
    track_clicks boolean not null default false,
    notify_on_engagement boolean not null default false,
    notify_min_confidence public.email_engagement_confidence not null default 'confirmed',
    notify_cooldown_minutes integer not null default 30 check (notify_cooldown_minutes >= 0),
    retention_days integer not null default 365 check (retention_days between 1 and 2555),
    lawful_basis text,
    privacy_notice_url text,
    updated_by uuid references public.profiles (id),
    updated_at timestamptz not null default now(),
    constraint email_engagement_basis_required check (
        (not track_opens and not track_clicks)
        or (lawful_basis is not null and length(btrim(lawful_basis)) > 0)
    )
);

comment on table public.email_engagement_settings is
  'Per-tenant engagement tracking switch. Tracking an identified individual needs a documented lawful basis, so the constraint requires one before either switch can be turned on.';
comment on column public.email_engagement_settings.notify_min_confidence is
  'Only engagement at or above this confidence raises a notification. Defaults to confirmed so a scanner never triggers a phone call.';

create trigger email_engagement_settings_touch
    before update on public.email_engagement_settings
    for each row execute function public.sales_touch_updated_at();

-- Reading view: machine events excluded, so the ordinary case cannot
-- accidentally present a scanner as a prospect.
create view public.v_email_engagement_human as
select * from public.email_engagement_events where confidence <> 'machine';

comment on view public.v_email_engagement_human is
  'Engagement with machine-attributed events removed. Query the base table when auditing what was filtered and why.';

alter table public.outbound_tracked_links enable row level security;
alter table public.email_engagement_events enable row level security;
alter table public.email_engagement_settings enable row level security;

create policy outbound_tracked_links_org on public.outbound_tracked_links
    for all using (public.sales_org_access(organization_id))
    with check (public.sales_org_access(organization_id));

create policy email_engagement_events_org on public.email_engagement_events
    for all using (public.sales_org_access(organization_id))
    with check (public.sales_org_access(organization_id));

create policy email_engagement_settings_org on public.email_engagement_settings
    for all using (public.sales_org_access(organization_id))
    with check (public.sales_org_access(organization_id));
