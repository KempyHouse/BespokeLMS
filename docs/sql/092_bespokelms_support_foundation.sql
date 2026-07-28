-- =============================================================================
-- 092_bespokelms_support_foundation.sql
-- BespokeLMS — Support Desk / Knowledge Base / Support Portal, Phase 0.
--
-- Migration name (apply_migration): bespokelms_support_foundation_092
--
-- Foundation only: no tickets yet. Establishes
--   * business_calendars    — operating hours + holidays (SLA prerequisite)
--   * support_desks         — one desk per platform/operator org, per-desk
--                             tenant-branded reference counter (decision C11)
--   * support_ticket_groups — teams within a desk
--   * support_agents        — profile <-> desk membership, skills, capacity
--   * support_access_grants — audited, time-limited break-glass (decision D1)
--   * helper functions      — support_desk_access / support_desk_admin /
--                             support_next_reference
--   * module seeds          — support_desk / knowledge_base / support_portal
--                             as THREE separate keys (decision D4)
--
-- Decisions encoded here (see BespokeLMS-Support-Desk-KB-Portal-Proposal.md):
--   D1  the platform owner reads its OWN desks freely; another controller's
--       desk requires a live support_access_grants row. Enforced in
--       support_desk_access(), not in the UI.
--   D4  three module keys, so a tenant can buy the KB + portal without a desk.
--   C11 references are `{prefix}-{n}` with the counter PER DESK, so ticket
--       volume never leaks across tenants.
--
-- Conventions: snake_case, lowercase reserved words, timestamptz, RLS on every
-- table, org-EXACT isolation (never org_and_descendants) for desk data.
-- Additive and safe to run once on top of 001-040.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Extensions
-- -----------------------------------------------------------------------------

create extension if not exists citext with schema public;
create extension if not exists unaccent with schema public;

-- -----------------------------------------------------------------------------
-- 2. Enums
-- -----------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_type where typname = 'support_agent_role') then
        create type support_agent_role as enum ('agent', 'supervisor', 'admin');
    end if;

    if not exists (select 1 from pg_type where typname = 'support_assignment_strategy') then
        create type support_assignment_strategy as enum ('manual', 'round_robin', 'load_balanced', 'skills');
    end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Domains — NOT created here.
--
-- An earlier draft of this migration created `organization_domains`. The
-- platform already has `tenant_domains` (migrations bespokelms_tenant_domains_044
-- / _managed_061): organization_id, hostname, surface, is_primary,
-- verification_token, verified_at, ssl_status, site_id, managed. That is the
-- host -> organisation lookup, it is wired to the web CMS (web_sites.site_id)
-- and to TenantDomainController, and a second table would fork the truth.
--
-- The support portal (a later phase) therefore hangs off tenant_domains and
-- web_sites, not off anything defined here.
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 4. business_calendars — operating hours (SLA prerequisite, used from 044)
-- -----------------------------------------------------------------------------

create table if not exists business_calendars (
    id                       uuid primary key default gen_random_uuid(),
    owning_organization_id   uuid not null references organizations (id) on delete cascade,
    name                     text not null,
    timezone                 text not null default 'Europe/London',
    -- week_hours: {"mon":[["09:00","17:30"]], ... } — a list of windows per day
    -- so split shifts are representable. Empty array = closed that day.
    week_hours               jsonb not null default
        '{"mon":[["09:00","17:30"]],"tue":[["09:00","17:30"]],"wed":[["09:00","17:30"]],"thu":[["09:00","17:30"]],"fri":[["09:00","17:00"]],"sat":[],"sun":[]}'::jsonb,
    is_default               boolean not null default false,
    created_by               uuid references profiles (id) on delete set null,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    constraint business_calendars_name_unique unique (owning_organization_id, name)
);

comment on table business_calendars is
    'Operating-hours definitions per organisation. SLA clocks (migration 044) only advance inside these windows and outside holidays.';

create unique index if not exists business_calendars_one_default
    on business_calendars (owning_organization_id)
    where is_default;

create table if not exists business_calendar_holidays (
    id                       uuid primary key default gen_random_uuid(),
    calendar_id              uuid not null references business_calendars (id) on delete cascade,
    holiday_date             date not null,
    label                    text not null,
    is_recurring_annually    boolean not null default false,
    created_at               timestamptz not null default now(),
    constraint business_calendar_holidays_unique unique (calendar_id, holiday_date)
);

-- -----------------------------------------------------------------------------
-- 5. support_desks
--
-- A desk belongs to exactly one organisation and only platform/operator orgs
-- may own one; client organisations are requesters on their operator's desk
-- (decision D3). Enforced by a guard trigger because a CHECK cannot look at
-- another table.
-- -----------------------------------------------------------------------------

create table if not exists support_desks (
    id                       uuid primary key default gen_random_uuid(),
    organization_id          uuid not null references organizations (id) on delete cascade,
    key                      text not null,
    name                     text not null,
    description              text,
    reference_prefix         text not null,
    next_reference           bigint not null default 1,
    business_calendar_id     uuid references business_calendars (id) on delete set null,
    default_group_id         uuid,   -- FK added after support_ticket_groups exists
    timezone                 text not null default 'Europe/London',
    default_locale           text not null default 'en-GB',
    is_active                boolean not null default true,
    settings                 jsonb not null default '{}'::jsonb,
    created_by               uuid references profiles (id) on delete set null,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    constraint support_desks_key_unique unique (organization_id, key),
    constraint support_desks_key_shape check (key ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'),
    constraint support_desks_prefix_shape check (reference_prefix ~ '^[A-Z][A-Z0-9]{1,7}$'),
    constraint support_desks_next_reference_positive check (next_reference >= 1)
);

comment on table support_desks is
    'One support desk per platform or operator organisation. reference_prefix + next_reference produce tenant-branded, per-desk ticket references (TP-1042) so ticket volume never leaks across tenants.';

create unique index if not exists support_desks_prefix_unique
    on support_desks (reference_prefix);

create index if not exists support_desks_org_idx
    on support_desks (organization_id)
    where is_active;

create or replace function support_desk_org_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_type org_type;
begin
    select type into v_type from organizations where id = new.organization_id;

    if v_type is null then
        raise exception 'support_desks: organisation % does not exist', new.organization_id;
    end if;

    if v_type not in ('platform', 'operator') then
        raise exception
            'support_desks: only platform or operator organisations may own a desk (% is %). Client organisations are requesters on their operator''s desk.',
            new.organization_id, v_type;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_desks_org_guard on support_desks;
create trigger trg_support_desks_org_guard
    before insert or update of organization_id on support_desks
    for each row execute function support_desk_org_guard();

-- -----------------------------------------------------------------------------
-- 6. support_ticket_groups
-- -----------------------------------------------------------------------------

create table if not exists support_ticket_groups (
    id                       uuid primary key default gen_random_uuid(),
    desk_id                  uuid not null references support_desks (id) on delete cascade,
    owning_organization_id   uuid not null references organizations (id) on delete cascade,
    key                      text not null,
    name                     text not null,
    description              text,
    email_alias              citext,
    business_calendar_id     uuid references business_calendars (id) on delete set null,
    assignment_strategy      support_assignment_strategy not null default 'manual',
    is_default               boolean not null default false,
    sort_order               integer not null default 0,
    is_active                boolean not null default true,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    constraint support_ticket_groups_key_unique unique (desk_id, key),
    constraint support_ticket_groups_key_shape check (key ~ '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$')
);

create unique index if not exists support_ticket_groups_one_default
    on support_ticket_groups (desk_id)
    where is_default;

alter table support_desks
    drop constraint if exists support_desks_default_group_fk;
alter table support_desks
    add constraint support_desks_default_group_fk
    foreign key (default_group_id) references support_ticket_groups (id) on delete set null;

-- -----------------------------------------------------------------------------
-- 7. support_agents
--
-- A profile in the desk's own organisation, or a platform profile (so your
-- staff can agent on the desks of brands you own outright). Guard trigger,
-- because the rule spans three tables.
-- -----------------------------------------------------------------------------

create table if not exists support_agents (
    id                       uuid primary key default gen_random_uuid(),
    desk_id                  uuid not null references support_desks (id) on delete cascade,
    owning_organization_id   uuid not null references organizations (id) on delete cascade,
    profile_id               uuid not null references profiles (id) on delete cascade,
    agent_role               support_agent_role not null default 'agent',
    default_group_id         uuid references support_ticket_groups (id) on delete set null,
    max_open_tickets         integer,
    skills                   text[] not null default '{}',
    is_available             boolean not null default true,
    signature_html           text,
    created_by               uuid references profiles (id) on delete set null,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    constraint support_agents_unique unique (desk_id, profile_id),
    constraint support_agents_capacity_positive check (max_open_tickets is null or max_open_tickets > 0)
);

create index if not exists support_agents_profile_idx
    on support_agents (profile_id)
    where is_available;

create or replace function support_agent_membership_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_desk_org    uuid;
    v_profile_org uuid;
    v_platform_id uuid;
begin
    select organization_id into v_desk_org from support_desks where id = new.desk_id;
    select organization_id into v_profile_org from profiles where id = new.profile_id;
    select id into v_platform_id from organizations where type = 'platform' limit 1;

    if v_desk_org is null or v_profile_org is null then
        raise exception 'support_agents: desk or profile does not exist';
    end if;

    if new.owning_organization_id is distinct from v_desk_org then
        raise exception 'support_agents: owning_organization_id must equal the desk organisation';
    end if;

    if v_profile_org <> v_desk_org and v_profile_org <> v_platform_id then
        raise exception
            'support_agents: profile % belongs to organisation % and cannot agent on a desk owned by %',
            new.profile_id, v_profile_org, v_desk_org;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_agents_membership_guard on support_agents;
create trigger trg_support_agents_membership_guard
    before insert or update of desk_id, profile_id, owning_organization_id on support_agents
    for each row execute function support_agent_membership_guard();

-- -----------------------------------------------------------------------------
-- 8. support_access_grants — break-glass (decision D1)
--
-- The ONLY route by which the platform reads another controller's ticket
-- content. Reason mandatory, time-limited, revocable, tenant-notified, and
-- every read under a grant also writes audit_log from the application layer.
-- -----------------------------------------------------------------------------

create table if not exists support_access_grants (
    id                       uuid primary key default gen_random_uuid(),
    granted_to_profile_id    uuid not null references profiles (id) on delete cascade,
    desk_id                  uuid not null references support_desks (id) on delete cascade,
    ticket_id                uuid,   -- FK added in 042; null = whole desk
    reason                   text not null,
    granted_by               uuid references profiles (id) on delete set null,
    granted_at               timestamptz not null default now(),
    expires_at               timestamptz not null,
    revoked_at               timestamptz,
    revoked_by               uuid references profiles (id) on delete set null,
    tenant_notified_at       timestamptz,
    created_at               timestamptz not null default now(),
    constraint support_access_grants_reason_meaningful check (length(btrim(reason)) >= 20),
    constraint support_access_grants_window check (expires_at > granted_at),
    constraint support_access_grants_max_window check (expires_at <= granted_at + interval '24 hours')
);

comment on table support_access_grants is
    'Break-glass: time-limited, reasoned, audited access for a platform profile to another organisation''s desk or single ticket. Surfaced to the tenant so every look is visible to them.';

create index if not exists support_access_grants_live_idx
    on support_access_grants (granted_to_profile_id, desk_id, expires_at)
    where revoked_at is null;

-- -----------------------------------------------------------------------------
-- 9. Helper functions
-- -----------------------------------------------------------------------------

-- Is there a live break-glass grant for the calling user over this desk/ticket?
create or replace function support_break_glass(desk uuid, ticket uuid default null)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select exists (
        select 1
        from support_access_grants g
        join profiles p on p.id = g.granted_to_profile_id
        where p.auth_user_id = auth.uid()
          and g.desk_id = desk
          and g.revoked_at is null
          and g.expires_at > now()
          and (g.ticket_id is null or ticket is null or g.ticket_id = ticket)
    );
$$;

-- May the calling user work on this desk at all?
--
-- Org-EXACT by design: the platform owner's own profile sits in the platform
-- organisation, so they reach the platform's desks (and the desks of brands
-- they own outright, once a desk exists there) with no special case, and reach
-- nothing else without a break-glass grant. This is decision D1 in one place.
create or replace function support_desk_access(desk uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select exists (
        select 1
        from support_desks d
        join profiles p on p.auth_user_id = auth.uid()
        where d.id = desk
          and module_enabled(d.organization_id, 'support_desk')
          and p.organization_id = d.organization_id
          and (
                p.role in ('bespokelms_owner', 'lms_operator_admin')
             or exists (
                    select 1 from profile_capabilities pc
                    where pc.profile_id = p.id
                      and pc.capability in ('support', 'support_admin')
                )
          )
    )
    or support_break_glass(desk, null);
$$;

-- May the calling user change the desk's configuration (groups, agents, SLA,
-- automation)? Never satisfiable by break-glass — reading in an emergency is
-- one thing, reconfiguring someone else's desk is another.
create or replace function support_desk_admin(desk uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select exists (
        select 1
        from support_desks d
        join profiles p on p.auth_user_id = auth.uid()
        where d.id = desk
          and module_enabled(d.organization_id, 'support_desk')
          and p.organization_id = d.organization_id
          and (
                p.role in ('bespokelms_owner', 'lms_operator_admin')
             or exists (
                    select 1 from profile_capabilities pc
                    where pc.profile_id = p.id and pc.capability = 'support_admin'
                )
          )
    );
$$;

-- Allocate the next tenant-branded reference for a desk (decision C11).
-- The row update takes a lock, so concurrent inserts serialise and the
-- sequence is gap-free within a desk.
create or replace function support_next_reference(desk uuid)
returns text
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
    v_prefix text;
    v_number bigint;
begin
    update support_desks
       set next_reference = next_reference + 1,
           updated_at     = now()
     where id = desk
    returning reference_prefix, next_reference - 1 into v_prefix, v_number;

    if v_prefix is null then
        raise exception 'support_next_reference: desk % does not exist', desk;
    end if;

    return v_prefix || '-' || v_number::text;
end;
$$;

-- -----------------------------------------------------------------------------
-- 10. updated_at triggers
-- -----------------------------------------------------------------------------

create or replace function support_touch_updated_at()
returns trigger
language plpgsql
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

do $$
declare
    t text;
begin
    foreach t in array array[
        'business_calendars',
        'support_desks',
        'support_ticket_groups',
        'support_agents'
    ]
    loop
        execute format('drop trigger if exists trg_%s_touch on %I', t, t);
        execute format(
            'create trigger trg_%s_touch before update on %I for each row execute function support_touch_updated_at()',
            t, t
        );
    end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Row-Level Security
-- -----------------------------------------------------------------------------

alter table business_calendars          enable row level security;
alter table business_calendar_holidays  enable row level security;
alter table support_desks               enable row level security;
alter table support_ticket_groups       enable row level security;
alter table support_agents              enable row level security;
alter table support_access_grants       enable row level security;

-- Calendars: org-exact, admin tiers only.
drop policy if exists business_calendars_org on business_calendars;
create policy business_calendars_org on business_calendars
    for all
    using (owning_organization_id = auth_org_id() and is_admin())
    with check (owning_organization_id = auth_org_id() and is_admin());

drop policy if exists business_calendar_holidays_org on business_calendar_holidays;
create policy business_calendar_holidays_org on business_calendar_holidays
    for all
    using (exists (
        select 1 from business_calendars c
        where c.id = calendar_id
          and c.owning_organization_id = auth_org_id()
          and is_admin()
    ))
    with check (exists (
        select 1 from business_calendars c
        where c.id = calendar_id
          and c.owning_organization_id = auth_org_id()
          and is_admin()
    ));

-- Desks: readable by anyone with desk access; writable by desk admins only.
drop policy if exists support_desks_read on support_desks;
create policy support_desks_read on support_desks
    for select
    using (support_desk_access(id));

drop policy if exists support_desks_write on support_desks;
create policy support_desks_write on support_desks
    for all
    using (support_desk_admin(id))
    with check (support_desk_admin(id));

drop policy if exists support_ticket_groups_read on support_ticket_groups;
create policy support_ticket_groups_read on support_ticket_groups
    for select
    using (support_desk_access(desk_id));

drop policy if exists support_ticket_groups_write on support_ticket_groups;
create policy support_ticket_groups_write on support_ticket_groups
    for all
    using (support_desk_admin(desk_id))
    with check (support_desk_admin(desk_id));

drop policy if exists support_agents_read on support_agents;
create policy support_agents_read on support_agents
    for select
    using (support_desk_access(desk_id) or profile_id = my_profile_id());

drop policy if exists support_agents_write on support_agents;
create policy support_agents_write on support_agents
    for all
    using (support_desk_admin(desk_id))
    with check (support_desk_admin(desk_id));

-- Break-glass grants: the platform owner creates them; the affected tenant's
-- admins can always read the grants over their own desk. That visibility is
-- the point — it is what makes the capability acceptable rather than alarming.
drop policy if exists support_access_grants_owner on support_access_grants;
create policy support_access_grants_owner on support_access_grants
    for all
    using (is_platform_owner())
    with check (is_platform_owner());

drop policy if exists support_access_grants_tenant_read on support_access_grants;
create policy support_access_grants_tenant_read on support_access_grants
    for select
    using (exists (
        select 1 from support_desks d
        where d.id = desk_id
          and d.organization_id = auth_org_id()
          and is_admin()
    ));

drop policy if exists support_access_grants_self_read on support_access_grants;
create policy support_access_grants_self_read on support_access_grants
    for select
    using (granted_to_profile_id = my_profile_id());

-- -----------------------------------------------------------------------------
-- 12. Grants
-- -----------------------------------------------------------------------------

grant select, insert, update, delete on
    business_calendars,
    business_calendar_holidays,
    support_desks,
    support_ticket_groups,
    support_agents,
    support_access_grants
to authenticated;

grant execute on function support_break_glass(uuid, uuid)   to authenticated;
grant execute on function support_desk_access(uuid)          to authenticated;
grant execute on function support_desk_admin(uuid)           to authenticated;
grant execute on function support_next_reference(uuid)       to authenticated;

-- -----------------------------------------------------------------------------
-- 13. Seed — the platform's own desk (Phase 1 runs on this, and only this)
--
-- Three module keys (decision D4), enabled for the BespokeLMS platform org
-- only. No other tenant gets a desk until you enable it from the tenant
-- console; EnsureModuleEnabled fails closed, so absence means 404.
-- -----------------------------------------------------------------------------

do $$
declare
    v_platform_id uuid;
    v_owner_id    uuid;
    v_calendar_id uuid;
    v_desk_id     uuid;
    v_group_id    uuid;
begin
    select id into v_platform_id from organizations where type = 'platform' limit 1;
    if v_platform_id is null then
        raise exception '092: no platform organisation found — run 001/002 first';
    end if;

    select id into v_owner_id
      from profiles
     where organization_id = v_platform_id and role = 'bespokelms_owner'
     order by created_at
     limit 1;

    -- Modules
    insert into tenant_modules (organization_id, module_key, enabled, enabled_at, enabled_by, settings)
    values
        (v_platform_id, 'support_desk',    true, now(), v_owner_id,
         jsonb_build_object('support_retention_months', 36, 'allow_client_desks', false)),
        (v_platform_id, 'knowledge_base',  true, now(), v_owner_id, '{}'::jsonb),
        (v_platform_id, 'support_portal',  false, null, null,
         jsonb_build_object('require_login_to_submit', true, 'allow_anonymous_submit', false))
    on conflict (organization_id, module_key) do nothing;

    -- Business calendar (UK office hours)
    insert into business_calendars (owning_organization_id, name, timezone, is_default, created_by)
    values (v_platform_id, 'UK office hours', 'Europe/London', true, v_owner_id)
    on conflict (owning_organization_id, name) do nothing
    returning id into v_calendar_id;

    if v_calendar_id is null then
        select id into v_calendar_id
          from business_calendars
         where owning_organization_id = v_platform_id and name = 'UK office hours';
    end if;

    -- England & Wales bank holidays for the remainder of 2026.
    insert into business_calendar_holidays (calendar_id, holiday_date, label)
    values
        (v_calendar_id, date '2026-08-31', 'Summer bank holiday'),
        (v_calendar_id, date '2026-12-25', 'Christmas Day'),
        (v_calendar_id, date '2026-12-28', 'Boxing Day (substitute)')
    on conflict (calendar_id, holiday_date) do nothing;

    -- The desk
    insert into support_desks (
        organization_id, key, name, description,
        reference_prefix, business_calendar_id, timezone, created_by
    )
    values (
        v_platform_id, 'platform-support', 'BespokeLMS Support',
        'Platform support for tenant administrators and internal staff.',
        'BLMS', v_calendar_id, 'Europe/London', v_owner_id
    )
    on conflict (organization_id, key) do nothing
    returning id into v_desk_id;

    if v_desk_id is null then
        select id into v_desk_id
          from support_desks
         where organization_id = v_platform_id and key = 'platform-support';
    end if;

    -- Groups
    insert into support_ticket_groups (desk_id, owning_organization_id, key, name, description, is_default, sort_order)
    values
        (v_desk_id, v_platform_id, 'general',   'General',   'Anything not yet triaged.', true,  10),
        (v_desk_id, v_platform_id, 'technical', 'Technical', 'Platform faults, access and integrations.', false, 20),
        (v_desk_id, v_platform_id, 'content',   'Content',   'Course and knowledge-base content issues.', false, 30),
        (v_desk_id, v_platform_id, 'billing',   'Billing',   'Invoices, licences and subscriptions.', false, 40)
    on conflict (desk_id, key) do nothing;

    select id into v_group_id
      from support_ticket_groups
     where desk_id = v_desk_id and key = 'general';

    update support_desks
       set default_group_id = v_group_id
     where id = v_desk_id and default_group_id is null;

    -- The owner as the first agent
    if v_owner_id is not null then
        insert into support_agents (
            desk_id, owning_organization_id, profile_id, agent_role, default_group_id, created_by
        )
        values (v_desk_id, v_platform_id, v_owner_id, 'admin', v_group_id, v_owner_id)
        on conflict (desk_id, profile_id) do nothing;
    end if;
end;
$$;

commit;

-- =============================================================================
-- 14. OPTIONAL, SEPARATE: citext retrofit for CRM email columns
--
-- Run this block ONLY when you are ready. It is correct but it touches live
-- CRM tables, so it is deliberately outside the transaction above and can be
-- deferred without blocking anything in 042/043/052.
--
-- Why: crm_contacts.email and crm_contact_emails.email are plain `text`, so
-- Andrew@x.com and andrew@x.com are two different contacts today and the
-- partial unique index does not catch it. Support requester auto-linking
-- matches on email, which makes this latent bug start to matter.
--
-- The pre-check raises rather than silently failing on a duplicate.
-- =============================================================================

-- do $$
-- declare
--     v_dupes integer;
-- begin
--     select count(*) into v_dupes from (
--         select owning_organization_id, lower(email)
--           from crm_contact_emails
--          group by 1, 2 having count(*) > 1
--     ) d;
--     if v_dupes > 0 then
--         raise exception 'citext retrofit: % case-duplicate address group(s) in crm_contact_emails — merge them first', v_dupes;
--     end if;
--
--     select count(*) into v_dupes from (
--         select owning_organization_id, lower(email)
--           from crm_contacts
--          where email is not null and archived_at is null
--          group by 1, 2 having count(*) > 1
--     ) d;
--     if v_dupes > 0 then
--         raise exception 'citext retrofit: % case-duplicate contact email group(s) in crm_contacts — merge them first', v_dupes;
--     end if;
-- end;
-- $$;
--
-- alter table crm_contacts       alter column email type citext using email::citext;
-- alter table crm_contact_emails alter column email type citext using email::citext;
