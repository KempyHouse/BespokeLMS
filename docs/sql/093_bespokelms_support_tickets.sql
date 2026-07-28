-- =============================================================================
-- 093_bespokelms_support_tickets.sql
-- BespokeLMS — Support Desk, Phase 1: the ticket core.
--
-- Migration name (apply_migration): bespokelms_support_tickets_093
-- Depends on: 092.
--
--   * support_tickets        — the record, with the requester TRIPLE
--                              (profile / CRM contact / raw email) so an
--                              unknown sender is representable without
--                              inventing a marketable CRM contact (C12)
--   * support_ticket_fields  — per-desk custom + dependent fields, values in
--                              support_tickets.custom
--   * support_ticket_watchers / _links / _tags / _events
--   * support_ticket_access(ticket) — the single authorisation predicate
--
-- Isolation: org-EXACT for the desk (who may work the ticket); the requester
-- side deliberately allows the desk organisation's SUBTREE, because Turner
-- Price's desk legitimately serves All Saints' users. That is the only place
-- subtree logic is correct in this module.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Enums
-- -----------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_type where typname = 'support_ticket_status') then
        create type support_ticket_status as enum (
            'new', 'open', 'pending_customer', 'pending_third_party',
            'on_hold', 'resolved', 'closed', 'spam', 'deleted'
        );
    end if;

    if not exists (select 1 from pg_type where typname = 'support_priority') then
        create type support_priority as enum ('low', 'medium', 'high', 'urgent');
    end if;

    if not exists (select 1 from pg_type where typname = 'support_channel') then
        create type support_channel as enum (
            'email', 'portal', 'chat', 'phone', 'api', 'form', 'internal', 'escalation'
        );
    end if;

    if not exists (select 1 from pg_type where typname = 'support_ticket_type') then
        create type support_ticket_type as enum (
            'question', 'incident', 'problem', 'feature_request',
            'task', 'complaint', 'access_request'
        );
    end if;

    if not exists (select 1 from pg_type where typname = 'support_field_type') then
        create type support_field_type as enum (
            'text', 'textarea', 'number', 'date', 'select', 'multiselect', 'checkbox'
        );
    end if;

    if not exists (select 1 from pg_type where typname = 'support_ticket_link_type') then
        create type support_ticket_link_type as enum (
            'merge', 'parent', 'child', 'related', 'duplicate'
        );
    end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. support_tickets
-- -----------------------------------------------------------------------------

create table if not exists support_tickets (
    id                        uuid primary key default gen_random_uuid(),
    owning_organization_id    uuid not null references organizations (id) on delete cascade,
    desk_id                   uuid not null references support_desks (id) on delete cascade,
    reference                 text not null,

    subject                   text not null,
    status                    support_ticket_status not null default 'new',
    priority                  support_priority not null default 'medium',
    ticket_type               support_ticket_type not null default 'question',
    channel                   support_channel not null default 'internal',

    group_id                  uuid references support_ticket_groups (id) on delete set null,
    assignee_profile_id       uuid references profiles (id) on delete set null,

    -- Requester triple (C12). At least one must be present. A ticket may be
    -- raised by a platform user, by a known CRM contact, or by an address we
    -- have never seen — and the third case must NOT silently create a contact.
    requester_profile_id      uuid references profiles (id) on delete set null,
    requester_contact_id      uuid references crm_contacts (id) on delete set null,
    requester_email           citext,
    requester_name            text,
    requester_organization_id uuid references organizations (id) on delete set null,

    -- Optional CRM anchor, so the account page can show support health.
    account_id                uuid references crm_accounts (id) on delete set null,

    -- Polymorphic "what is this ticket about" hook: course, enrollment,
    -- certificate, work_item, support_article. Deliberately not an FK — the
    -- referenced tables live in different modules with different lifecycles.
    subject_entity_type       text,
    subject_entity_id         uuid,

    source_detail             text,
    custom                    jsonb not null default '{}'::jsonb,
    spam_score                numeric(5, 4),

    -- SLA stamps live here for cheap indexing; the policy ledger arrives in 044.
    first_response_due_at     timestamptz,
    resolution_due_at         timestamptz,
    first_responded_at        timestamptz,
    resolved_at               timestamptz,
    closed_at                 timestamptz,
    reopened_count            integer not null default 0,
    last_requester_reply_at   timestamptz,
    last_agent_reply_at       timestamptz,

    -- Escalation (C1) — a NEW ticket on the receiving desk, never a
    -- cross-tenant read of the original.
    parent_ticket_id          uuid references support_tickets (id) on delete set null,
    escalated_to_organization_id uuid references organizations (id) on delete set null,
    escalated_at              timestamptz,
    merged_into_ticket_id     uuid references support_tickets (id) on delete set null,

    archived_at               timestamptz,
    created_by                uuid references profiles (id) on delete set null,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),

    constraint support_tickets_reference_unique unique (desk_id, reference),
    constraint support_tickets_requester_present check (
        requester_profile_id is not null
        or requester_contact_id is not null
        or requester_email is not null
    ),
    constraint support_tickets_subject_entity_pair check (
        (subject_entity_type is null and subject_entity_id is null)
        or (subject_entity_type is not null and subject_entity_id is not null)
    ),
    constraint support_tickets_subject_entity_known check (
        subject_entity_type is null or subject_entity_type in (
            'course', 'course_version', 'enrollment', 'certificate',
            'work_item', 'support_article', 'organization', 'profile'
        )
    ),
    constraint support_tickets_no_self_parent check (parent_ticket_id is distinct from id),
    constraint support_tickets_no_self_merge check (merged_into_ticket_id is distinct from id),
    constraint support_tickets_reopened_non_negative check (reopened_count >= 0),
    constraint support_tickets_spam_score_range check (
        spam_score is null or (spam_score >= 0 and spam_score <= 1)
    )
);

comment on table support_tickets is
    'A support request on one desk. owning_organization_id is the isolation anchor (whose desk it is); requester_organization_id records who is asking and may be anywhere in that desk organisation''s subtree.';
comment on column support_tickets.subject_entity_type is
    'Polymorphic hook: what the ticket is about (course, enrollment, certificate, work_item, support_article). Not an FK by design — cross-module, differing lifecycles.';
comment on column support_tickets.custom is
    'Values for the desk''s support_ticket_fields definitions. Validated in the Form Request against those definitions, never free-form.';

create index if not exists support_tickets_queue_idx
    on support_tickets (desk_id, status, priority, created_at desc);

create index if not exists support_tickets_assignee_idx
    on support_tickets (desk_id, assignee_profile_id, status);

create index if not exists support_tickets_org_recent_idx
    on support_tickets (owning_organization_id, created_at desc);

create index if not exists support_tickets_requester_contact_idx
    on support_tickets (requester_contact_id)
    where requester_contact_id is not null;

create index if not exists support_tickets_requester_profile_idx
    on support_tickets (requester_profile_id)
    where requester_profile_id is not null;

create index if not exists support_tickets_requester_email_idx
    on support_tickets (owning_organization_id, requester_email)
    where requester_email is not null;

create index if not exists support_tickets_account_idx
    on support_tickets (account_id)
    where account_id is not null;

create index if not exists support_tickets_subject_entity_idx
    on support_tickets (subject_entity_type, subject_entity_id)
    where subject_entity_type is not null;

create index if not exists support_tickets_sla_open_idx
    on support_tickets (desk_id, resolution_due_at)
    where status not in ('resolved', 'closed', 'spam', 'deleted');

create index if not exists support_tickets_custom_idx
    on support_tickets using gin (custom);

create index if not exists support_tickets_subject_trgm_idx
    on support_tickets using gin (subject gin_trgm_ops);

-- support_access_grants.ticket_id could not be a FK until now.
alter table support_access_grants
    drop constraint if exists support_access_grants_ticket_fk;
alter table support_access_grants
    add constraint support_access_grants_ticket_fk
    foreign key (ticket_id) references support_tickets (id) on delete cascade;

-- -----------------------------------------------------------------------------
-- 3. support_ticket_fields — per-desk custom and dependent fields
-- -----------------------------------------------------------------------------

create table if not exists support_ticket_fields (
    id                        uuid primary key default gen_random_uuid(),
    desk_id                   uuid not null references support_desks (id) on delete cascade,
    owning_organization_id    uuid not null references organizations (id) on delete cascade,
    key                       text not null,
    label                     text not null,
    help_text                 text,
    field_type                support_field_type not null default 'text',
    options                   jsonb not null default '[]'::jsonb,
    is_required_on_create     boolean not null default false,
    is_visible_to_requester   boolean not null default true,
    is_editable_by_requester  boolean not null default false,
    parent_field_key          text,
    parent_value              text,
    sort_order                integer not null default 0,
    is_active                 boolean not null default true,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),
    constraint support_ticket_fields_key_unique unique (desk_id, key),
    constraint support_ticket_fields_key_shape check (key ~ '^[a-z][a-z0-9_]{1,38}$'),
    constraint support_ticket_fields_dependency_pair check (
        (parent_field_key is null and parent_value is null)
        or (parent_field_key is not null and parent_value is not null)
    ),
    constraint support_ticket_fields_no_self_dependency check (
        parent_field_key is distinct from key
    )
);

-- -----------------------------------------------------------------------------
-- 4. Watchers, links, tags, events
-- -----------------------------------------------------------------------------

create table if not exists support_ticket_watchers (
    id           uuid primary key default gen_random_uuid(),
    ticket_id    uuid not null references support_tickets (id) on delete cascade,
    profile_id   uuid not null references profiles (id) on delete cascade,
    added_by     uuid references profiles (id) on delete set null,
    added_at     timestamptz not null default now(),
    constraint support_ticket_watchers_unique unique (ticket_id, profile_id)
);

create table if not exists support_ticket_links (
    id              uuid primary key default gen_random_uuid(),
    from_ticket_id  uuid not null references support_tickets (id) on delete cascade,
    to_ticket_id    uuid not null references support_tickets (id) on delete cascade,
    link_type       support_ticket_link_type not null default 'related',
    created_by      uuid references profiles (id) on delete set null,
    created_at      timestamptz not null default now(),
    constraint support_ticket_links_unique unique (from_ticket_id, to_ticket_id, link_type),
    constraint support_ticket_links_not_self check (from_ticket_id <> to_ticket_id)
);

create table if not exists support_ticket_tags (
    ticket_id   uuid not null references support_tickets (id) on delete cascade,
    tag_id      uuid not null references tags (id) on delete cascade,
    added_by    uuid references profiles (id) on delete set null,
    added_at    timestamptz not null default now(),
    primary key (ticket_id, tag_id)
);

-- The user-visible history inside a ticket. Separate from audit_log (which is
-- platform-wide and admin-facing) and from crm_activities (which is the
-- cross-module timeline and must stay light).
create table if not exists support_ticket_events (
    id                  uuid primary key default gen_random_uuid(),
    ticket_id           uuid not null references support_tickets (id) on delete cascade,
    event_type          text not null,
    from_value          text,
    to_value            text,
    field_key           text,
    actor_profile_id    uuid references profiles (id) on delete set null,
    automation_rule_id  uuid,
    note                text,
    created_at          timestamptz not null default now(),
    constraint support_ticket_events_type_known check (
        event_type in (
            'created', 'status_changed', 'priority_changed', 'type_changed',
            'assigned', 'unassigned', 'group_changed', 'field_changed',
            'merged', 'linked', 'escalated', 'reopened',
            'sla_stamped', 'sla_breached', 'csat_received',
            'watcher_added', 'watcher_removed', 'access_granted'
        )
    )
);

create index if not exists support_ticket_events_ticket_idx
    on support_ticket_events (ticket_id, created_at);

-- -----------------------------------------------------------------------------
-- 5. Guards and stamping triggers
-- -----------------------------------------------------------------------------

-- Reference allocation + org denormalisation + requester-subtree validation.
create or replace function support_ticket_before_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_desk_org uuid;
begin
    select organization_id into v_desk_org from support_desks where id = new.desk_id;
    if v_desk_org is null then
        raise exception 'support_tickets: desk % does not exist', new.desk_id;
    end if;

    new.owning_organization_id := v_desk_org;

    if new.reference is null or btrim(new.reference) = '' then
        new.reference := support_next_reference(new.desk_id);
    end if;

    -- The requester may be anywhere in the desk organisation's subtree. This
    -- is the one correct use of subtree logic in the module: Turner Price's
    -- desk serves All Saints' users, but it must never widen who can READ.
    if new.requester_organization_id is not null
       and new.requester_organization_id not in (select org_and_descendants(v_desk_org)) then
        raise exception
            'support_tickets: requester organisation % is not within the desk organisation''s estate (%)',
            new.requester_organization_id, v_desk_org;
    end if;

    -- A CRM contact requester must belong to the desk organisation's own CRM.
    -- Referencing another tenant's contact would be a controller breach.
    if new.requester_contact_id is not null
       and not exists (
           select 1 from crm_contacts c
           where c.id = new.requester_contact_id
             and c.owning_organization_id = v_desk_org
       ) then
        raise exception
            'support_tickets: CRM contact % does not belong to this desk''s CRM', new.requester_contact_id;
    end if;

    if new.account_id is not null
       and not exists (
           select 1 from crm_accounts a
           where a.id = new.account_id and a.owning_organization_id = v_desk_org
       ) then
        raise exception
            'support_tickets: CRM account % does not belong to this desk''s CRM', new.account_id;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_tickets_before_insert on support_tickets;
create trigger trg_support_tickets_before_insert
    before insert on support_tickets
    for each row execute function support_ticket_before_insert();

-- Status stamping: resolved/closed timestamps, reopen counting, updated_at.
create or replace function support_ticket_before_update()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();

    if new.status is distinct from old.status then
        if new.status = 'resolved' and old.status <> 'resolved' then
            new.resolved_at := coalesce(new.resolved_at, now());
        end if;

        if new.status = 'closed' and old.status <> 'closed' then
            new.closed_at := coalesce(new.closed_at, now());
            new.resolved_at := coalesce(new.resolved_at, now());
        end if;

        -- Reopening: from a terminal state back into a working state.
        if old.status in ('resolved', 'closed')
           and new.status in ('new', 'open', 'pending_customer', 'pending_third_party', 'on_hold') then
            new.reopened_count := old.reopened_count + 1;
            new.resolved_at := null;
            new.closed_at := null;
        end if;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_tickets_before_update on support_tickets;
create trigger trg_support_tickets_before_update
    before update on support_tickets
    for each row execute function support_ticket_before_update();

-- Ticket history, written by the database so no application path can skip it.
create or replace function support_ticket_log_changes()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_actor uuid := my_profile_id();
begin
    if tg_op = 'INSERT' then
        insert into support_ticket_events (ticket_id, event_type, to_value, actor_profile_id)
        values (new.id, 'created', new.status::text, coalesce(v_actor, new.created_by));
        return new;
    end if;

    if new.status is distinct from old.status then
        insert into support_ticket_events (ticket_id, event_type, from_value, to_value, actor_profile_id)
        values (new.id, 'status_changed', old.status::text, new.status::text, v_actor);

        if new.reopened_count > old.reopened_count then
            insert into support_ticket_events (ticket_id, event_type, from_value, to_value, actor_profile_id)
            values (new.id, 'reopened', old.status::text, new.status::text, v_actor);
        end if;
    end if;

    if new.priority is distinct from old.priority then
        insert into support_ticket_events (ticket_id, event_type, from_value, to_value, actor_profile_id)
        values (new.id, 'priority_changed', old.priority::text, new.priority::text, v_actor);
    end if;

    if new.ticket_type is distinct from old.ticket_type then
        insert into support_ticket_events (ticket_id, event_type, from_value, to_value, actor_profile_id)
        values (new.id, 'type_changed', old.ticket_type::text, new.ticket_type::text, v_actor);
    end if;

    if new.assignee_profile_id is distinct from old.assignee_profile_id then
        insert into support_ticket_events (ticket_id, event_type, from_value, to_value, actor_profile_id)
        values (
            new.id,
            case when new.assignee_profile_id is null then 'unassigned' else 'assigned' end,
            old.assignee_profile_id::text, new.assignee_profile_id::text, v_actor
        );
    end if;

    if new.group_id is distinct from old.group_id then
        insert into support_ticket_events (ticket_id, event_type, from_value, to_value, actor_profile_id)
        values (new.id, 'group_changed', old.group_id::text, new.group_id::text, v_actor);
    end if;

    if new.escalated_at is distinct from old.escalated_at and new.escalated_at is not null then
        insert into support_ticket_events (ticket_id, event_type, to_value, actor_profile_id)
        values (new.id, 'escalated', new.escalated_to_organization_id::text, v_actor);
    end if;

    if new.merged_into_ticket_id is distinct from old.merged_into_ticket_id
       and new.merged_into_ticket_id is not null then
        insert into support_ticket_events (ticket_id, event_type, to_value, actor_profile_id)
        values (new.id, 'merged', new.merged_into_ticket_id::text, v_actor);
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_tickets_log on support_tickets;
create trigger trg_support_tickets_log
    after insert or update on support_tickets
    for each row execute function support_ticket_log_changes();

drop trigger if exists trg_support_ticket_fields_touch on support_ticket_fields;
create trigger trg_support_ticket_fields_touch
    before update on support_ticket_fields
    for each row execute function support_touch_updated_at();

-- -----------------------------------------------------------------------------
-- 6. Authorisation predicate
-- -----------------------------------------------------------------------------

-- The single answer to "may the calling user see this ticket?".
--   agent side     — desk access (org-exact) or a live break-glass grant
--   requester side — the requester themselves, an admin of the requester's
--                    organisation, or the manager of the requester's team
create or replace function support_ticket_access(ticket uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select exists (
        select 1
        from support_tickets t
        where t.id = ticket
          and (
                support_desk_access(t.desk_id)
             or support_break_glass(t.desk_id, t.id)
             or t.requester_profile_id = my_profile_id()
             or (
                    t.requester_organization_id is not null
                and t.requester_organization_id = auth_org_id()
                and is_admin()
                )
          )
    );
$$;

-- Does the caller have a ticket on this desk as requester (themselves, or as
-- an admin of the requesting organisation)?
--
-- Needed because 041's support_desks policy is agent-side only, so a requester
-- could read their own ticket but not the desk row behind it — and every
-- practical query joins the desk for its name and reference prefix. Caught by
-- the isolation harness, which is exactly what it is for. SECURITY DEFINER so
-- the subquery does not re-enter support_tickets' own policy.
create or replace function support_desk_requester(desk uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select exists (
        select 1
        from support_tickets t
        where t.desk_id = desk
          and (
                t.requester_profile_id = my_profile_id()
             or (
                    t.requester_organization_id is not null
                and t.requester_organization_id = auth_org_id()
                and is_admin()
                )
          )
    );
$$;

-- May the caller MODIFY the ticket? Requesters may reply (043) but not
-- reassign, so agent-side only.
create or replace function support_ticket_manage(ticket uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
    select exists (
        select 1 from support_tickets t
        where t.id = ticket and support_desk_access(t.desk_id)
    );
$$;

-- -----------------------------------------------------------------------------
-- 7. Row-Level Security
-- -----------------------------------------------------------------------------

alter table support_tickets         enable row level security;
alter table support_ticket_fields   enable row level security;
alter table support_ticket_watchers enable row level security;
alter table support_ticket_links    enable row level security;
alter table support_ticket_tags     enable row level security;
alter table support_ticket_events   enable row level security;

-- Read-only sight of the desk for its own requesters (name, prefix, timezone).
-- Writes remain support_desk_admin only, from 041.
drop policy if exists support_desks_requester_read on support_desks;
create policy support_desks_requester_read on support_desks
    for select
    using (support_desk_requester(id));

drop policy if exists support_tickets_read on support_tickets;
create policy support_tickets_read on support_tickets
    for select
    using (support_ticket_access(id));

drop policy if exists support_tickets_insert on support_tickets;
create policy support_tickets_insert on support_tickets
    for insert
    with check (
        support_desk_access(desk_id)
        or requester_profile_id = my_profile_id()
    );

drop policy if exists support_tickets_update on support_tickets;
create policy support_tickets_update on support_tickets
    for update
    using (support_ticket_manage(id))
    with check (support_ticket_manage(id));

drop policy if exists support_ticket_fields_read on support_ticket_fields;
create policy support_ticket_fields_read on support_ticket_fields
    for select
    using (support_desk_access(desk_id));

drop policy if exists support_ticket_fields_write on support_ticket_fields;
create policy support_ticket_fields_write on support_ticket_fields
    for all
    using (support_desk_admin(desk_id))
    with check (support_desk_admin(desk_id));

drop policy if exists support_ticket_watchers_all on support_ticket_watchers;
create policy support_ticket_watchers_all on support_ticket_watchers
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id));

drop policy if exists support_ticket_links_all on support_ticket_links;
create policy support_ticket_links_all on support_ticket_links
    for all
    using (support_ticket_manage(from_ticket_id))
    with check (support_ticket_manage(from_ticket_id) and support_ticket_manage(to_ticket_id));

drop policy if exists support_ticket_tags_all on support_ticket_tags;
create policy support_ticket_tags_all on support_ticket_tags
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id));

drop policy if exists support_ticket_events_read on support_ticket_events;
create policy support_ticket_events_read on support_ticket_events
    for select
    using (support_ticket_access(ticket_id));

drop policy if exists support_ticket_events_insert on support_ticket_events;
create policy support_ticket_events_insert on support_ticket_events
    for insert
    with check (support_ticket_manage(ticket_id));

-- -----------------------------------------------------------------------------
-- 8. Grants
-- -----------------------------------------------------------------------------

grant select, insert, update, delete on
    support_tickets,
    support_ticket_fields,
    support_ticket_watchers,
    support_ticket_links,
    support_ticket_tags,
    support_ticket_events
to authenticated;

grant execute on function support_ticket_access(uuid)   to authenticated;
grant execute on function support_ticket_manage(uuid)   to authenticated;
grant execute on function support_desk_requester(uuid)  to authenticated;

commit;
