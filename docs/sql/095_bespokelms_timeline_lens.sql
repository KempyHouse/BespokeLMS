-- =============================================================================
-- 095_bespokelms_timeline_lens.sql
-- BespokeLMS — the role-aware unified timeline.
--
-- Migration name (apply_migration): bespokelms_timeline_lens_095
-- Depends on: 092, 042, 043 (and the CRM series 028-040).
--
-- Numbered 052 rather than 044 because it belongs to the timeline slice of the
-- support plan, and 044-051 are reserved for SLA, automation, KB, portal, CSAT
-- and inbound. Nothing between 044 and 051 is required for Phase 1, so this
-- file applies straight after 043.
--
-- Why this exists (proposal C4): roughly thirty Laravel bindings read with the
-- service-role key, which bypasses RLS entirely. Hiding a sales row in Blade is
-- not access control — it was already fetched. So the timeline needs columns
-- that a QUERY can filter on:
--
--     origin_module     sales | support | marketing | learning | system
--     confidentiality   normal | restricted
--
-- A support agent's lens fetches origin_module in (support, learning, system);
-- a salesperson's lens fetches everything except restricted support content,
-- so they can see that a customer raised three tickets last month (a churn
-- signal) without reading the complaints.
--
-- And per C3: support writes POINTER rows here, never conversation bodies.
-- The trigger below owns that, so no application path can forget it and no
-- message body is ever duplicated into the timeline.
-- =============================================================================

-- Enum additions run outside the transaction below: PostgreSQL will not let a
-- newly added enum label be used in the same transaction that adds it.

alter type crm_activity_type add value if not exists 'ticket';
alter type crm_record_source add value if not exists 'support_request';

begin;

-- -----------------------------------------------------------------------------
-- 1. The lens columns
-- -----------------------------------------------------------------------------

alter table crm_activities
    add column if not exists origin_module text not null default 'sales';

alter table crm_activities
    add column if not exists confidentiality text not null default 'normal';

alter table crm_activities
    add column if not exists ticket_id uuid;

do $$
begin
    if not exists (
        select 1 from pg_constraint where conname = 'crm_activities_ticket_fk'
    ) then
        alter table crm_activities
            add constraint crm_activities_ticket_fk
            foreign key (ticket_id) references support_tickets (id) on delete set null;
    end if;

    if not exists (
        select 1 from pg_constraint where conname = 'crm_activities_origin_module_valid'
    ) then
        alter table crm_activities
            add constraint crm_activities_origin_module_valid
            check (origin_module in ('sales', 'support', 'marketing', 'learning', 'system'));
    end if;

    if not exists (
        select 1 from pg_constraint where conname = 'crm_activities_confidentiality_valid'
    ) then
        alter table crm_activities
            add constraint crm_activities_confidentiality_valid
            check (confidentiality in ('normal', 'restricted'));
    end if;
end;
$$;

comment on column crm_activities.origin_module is
    'Which module produced this timeline row. Filtered at query time by the TimelineLens so the wrong rows are never fetched — service-role reads bypass RLS, so a Blade condition is not access control.';
comment on column crm_activities.confidentiality is
    'restricted = commercially or personally sensitive; requires the matching module capability even for a viewer who can see the rest of the timeline.';
comment on column crm_activities.ticket_id is
    'Pointer to the support ticket this row summarises. Conversation bodies live only in support_ticket_messages (proposal C3).';

-- Existing rows predate support and are all sales activity.
update crm_activities set origin_module = 'sales' where origin_module is null;

-- -----------------------------------------------------------------------------
-- 2. A ticket is now a valid timeline anchor
-- -----------------------------------------------------------------------------

alter table crm_activities drop constraint if exists crm_activities_anchor;
alter table crm_activities
    add constraint crm_activities_anchor check (
        account_id is not null
        or contact_id is not null
        or deal_id is not null
        or ticket_id is not null
    );

-- -----------------------------------------------------------------------------
-- 3. Indexes for the lens
-- -----------------------------------------------------------------------------

create index if not exists crm_activities_lens_idx
    on crm_activities (owning_organization_id, origin_module, happened_at desc);

create index if not exists crm_activities_ticket_idx
    on crm_activities (ticket_id)
    where ticket_id is not null;

-- -----------------------------------------------------------------------------
-- 4. Ticket -> timeline pointer rows
--
-- Written by the database so the timeline cannot silently drift from the desk.
-- One row per lifecycle event, one line of text, no bodies.
-- -----------------------------------------------------------------------------

create or replace function support_ticket_timeline_pointer()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_subject   text;
    v_direction crm_activity_direction;
    v_write     boolean := false;
    v_minutes   integer;
begin
    if tg_op = 'INSERT' then
        v_subject   := format('Ticket %s raised: %s', new.reference, new.subject);
        v_direction := 'inbound';
        v_write     := true;

    elsif new.first_responded_at is not null and old.first_responded_at is null then
        v_minutes := greatest(0, (extract(epoch from (new.first_responded_at - new.created_at)) / 60)::integer);
        v_subject := format('Ticket %s — first response sent (%s min)', new.reference, v_minutes);
        v_direction := 'outbound';
        v_write := true;

    elsif new.status is distinct from old.status
          and new.status in ('resolved', 'closed')
          and old.status not in ('resolved', 'closed') then
        v_subject := format('Ticket %s %s', new.reference, new.status::text);
        v_direction := 'outbound';
        v_write := true;

    elsif new.reopened_count > old.reopened_count then
        v_subject := format('Ticket %s reopened', new.reference);
        v_direction := 'inbound';
        v_write := true;

    elsif new.escalated_at is not null and old.escalated_at is null then
        v_subject := format('Ticket %s escalated', new.reference);
        v_direction := 'internal';
        v_write := true;
    end if;

    if not v_write then
        return new;
    end if;

    insert into crm_activities (
        owning_organization_id, activity_type, direction, subject,
        happened_at, actor_profile_id,
        account_id, contact_id, ticket_id,
        channel_refs, source, origin_module, confidentiality, created_by
    )
    values (
        new.owning_organization_id,
        'ticket',
        v_direction,
        v_subject,
        now(),
        coalesce(my_profile_id(), new.assignee_profile_id),
        new.account_id,
        new.requester_contact_id,
        new.id,
        jsonb_build_object(
            'ticket_id', new.id,
            'ticket_reference', new.reference,
            'desk_id', new.desk_id,
            'status', new.status::text,
            'priority', new.priority::text
        ),
        'support_request',
        'support',
        -- Complaints carry detail a sales viewer has no business reading; the
        -- card still appears, the body never does.
        case when new.ticket_type = 'complaint' then 'restricted' else 'normal' end,
        coalesce(my_profile_id(), new.created_by)
    );

    return new;
end;
$$;

drop trigger if exists trg_support_tickets_timeline on support_tickets;
create trigger trg_support_tickets_timeline
    after insert or update on support_tickets
    for each row execute function support_ticket_timeline_pointer();

-- -----------------------------------------------------------------------------
-- 5. Support health per CRM account — PII-free, safe for a sales viewer
-- -----------------------------------------------------------------------------

create or replace view v_crm_account_support_health
with (security_invoker = true) as
select
    t.owning_organization_id,
    t.account_id,
    count(*) filter (where t.status not in ('resolved', 'closed', 'spam', 'deleted')) as open_tickets,
    count(*) filter (where t.ticket_type = 'complaint'
                       and t.status not in ('resolved', 'closed', 'spam', 'deleted')) as open_complaints,
    count(*) filter (where t.created_at >= now() - interval '30 days')                as tickets_30d,
    count(*) filter (where t.reopened_count > 0)                                     as reopened_tickets,
    max(t.created_at)                                                                as last_ticket_at
from support_tickets t
where t.account_id is not null
  and t.archived_at is null
group by t.owning_organization_id, t.account_id;

comment on view v_crm_account_support_health is
    'Counts only — no subjects, no requester names. This is what a sales viewer sees on an account: enough to spot churn risk, nothing that breaches the support confidentiality boundary.';

grant select on v_crm_account_support_health to authenticated;

commit;
