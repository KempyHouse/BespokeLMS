-- =============================================================================
-- 094_bespokelms_support_conversations.sql
-- BespokeLMS — Support Desk, Phase 1: conversations, attachments, canned
-- responses, collision detection, reply-address tokens.
--
-- Migration name (apply_migration): bespokelms_support_conversations_094
-- Depends on: 092, 042.
--
-- support_ticket_messages is the SYSTEM OF RECORD for conversation content
-- (proposal C3). crm_activities receives pointer rows only (migration 052) so
-- the cross-module timeline stays light and every message body has exactly one
-- home for retention and erasure.
--
-- Private storage bucket `support-attachments`, path prefix
-- {owning_organization_id}/tickets/{ticket_id}/..., double-enforced by a CHECK
-- here and a storage policy below — the same hardening as crm-documents.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Enums
-- -----------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_type where typname = 'support_message_type') then
        create type support_message_type as enum (
            'public_reply', 'private_note', 'forward', 'system', 'csat_request'
        );
    end if;

    if not exists (select 1 from pg_type where typname = 'support_message_direction') then
        create type support_message_direction as enum ('inbound', 'outbound', 'internal');
    end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. support_ticket_messages
-- -----------------------------------------------------------------------------

create table if not exists support_ticket_messages (
    id                        uuid primary key default gen_random_uuid(),
    ticket_id                 uuid not null references support_tickets (id) on delete cascade,
    -- Denormalised from the ticket so RLS and retention sweeps do not join.
    owning_organization_id    uuid not null references organizations (id) on delete cascade,

    message_type              support_message_type not null default 'public_reply',
    direction                 support_message_direction not null default 'outbound',

    author_profile_id         uuid references profiles (id) on delete set null,
    author_contact_id         uuid references crm_contacts (id) on delete set null,
    author_email              citext,
    author_name               text,

    body_html                 text,
    body_plain                text,
    channel                   support_channel not null default 'internal',

    -- Email threading (see the proposal §11.2). Kept here, never in
    -- email_send_logs, which stays deliberately PII-free.
    provider_message_id       text,
    provider_thread_id        text,
    in_reply_to               text,
    email_references          text[],
    email_headers             jsonb,

    is_first_response         boolean not null default false,
    visible_to_requester      boolean not null default true,
    sent_at                   timestamptz,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),

    constraint support_ticket_messages_body_present check (
        coalesce(btrim(body_html), '') <> '' or coalesce(btrim(body_plain), '') <> ''
    ),
    constraint support_ticket_messages_author_present check (
        author_profile_id is not null
        or author_contact_id is not null
        or author_email is not null
        or message_type = 'system'
    )
);

comment on table support_ticket_messages is
    'The system of record for ticket conversation. Public replies are visible to the requester; private notes never are. Bodies live here and nowhere else, so erasure and retention have a single target.';
comment on column support_ticket_messages.visible_to_requester is
    'Derived from message_type by trigger and stored, so requester-facing queries are a single indexed predicate rather than an enum test.';

create index if not exists support_ticket_messages_thread_idx
    on support_ticket_messages (ticket_id, created_at);

create index if not exists support_ticket_messages_requester_thread_idx
    on support_ticket_messages (ticket_id, created_at)
    where visible_to_requester;

-- Inbound idempotency: the same provider webhook fires more than once.
create unique index if not exists support_ticket_messages_provider_unique
    on support_ticket_messages (provider_message_id)
    where provider_message_id is not null;

create index if not exists support_ticket_messages_in_reply_to_idx
    on support_ticket_messages (in_reply_to)
    where in_reply_to is not null;

-- -----------------------------------------------------------------------------
-- 3. support_attachments
-- -----------------------------------------------------------------------------

create table if not exists support_attachments (
    id                        uuid primary key default gen_random_uuid(),
    owning_organization_id    uuid not null references organizations (id) on delete cascade,
    ticket_id                 uuid not null references support_tickets (id) on delete cascade,
    message_id                uuid references support_ticket_messages (id) on delete cascade,
    storage_path              text not null,
    file_name                 text not null,
    mime_type                 text not null,
    byte_size                 bigint not null,
    scanned_at                timestamptz,
    scan_result               text,
    uploaded_by               uuid references profiles (id) on delete set null,
    created_at                timestamptz not null default now(),
    constraint support_attachments_path_unique unique (storage_path),
    constraint support_attachments_size_sane check (byte_size > 0 and byte_size <= 26214400),
    constraint support_attachments_scan_result_valid check (
        scan_result is null or scan_result in ('clean', 'infected', 'unscannable')
    ),
    -- Double enforcement #1: the path MUST begin with the owning organisation.
    constraint support_attachments_path_prefix check (
        storage_path like (owning_organization_id::text || '/tickets/%')
    )
);

create index if not exists support_attachments_ticket_idx
    on support_attachments (ticket_id, created_at);

-- -----------------------------------------------------------------------------
-- 4. support_canned_responses
-- -----------------------------------------------------------------------------

create table if not exists support_canned_responses (
    id                        uuid primary key default gen_random_uuid(),
    owning_organization_id    uuid not null references organizations (id) on delete cascade,
    desk_id                   uuid references support_desks (id) on delete cascade,
    group_id                  uuid references support_ticket_groups (id) on delete set null,
    shortcut                  text not null,
    title                     text not null,
    body_html                 text not null,
    is_shared                 boolean not null default true,
    created_by                uuid references profiles (id) on delete set null,
    usage_count               integer not null default 0,
    is_active                 boolean not null default true,
    created_at                timestamptz not null default now(),
    updated_at                timestamptz not null default now(),
    constraint support_canned_responses_shortcut_unique unique (owning_organization_id, shortcut),
    constraint support_canned_responses_shortcut_shape check (shortcut ~ '^[a-z0-9][a-z0-9._-]{1,38}$')
);

comment on table support_canned_responses is
    'Reusable replies. body_html is semantic only and passes through the same sanitiser as the branded email templates, on save and on render.';

-- -----------------------------------------------------------------------------
-- 5. support_ticket_viewers — collision detection without realtime
-- -----------------------------------------------------------------------------

create table if not exists support_ticket_viewers (
    ticket_id      uuid not null references support_tickets (id) on delete cascade,
    profile_id     uuid not null references profiles (id) on delete cascade,
    last_seen_at   timestamptz not null default now(),
    is_composing   boolean not null default false,
    primary key (ticket_id, profile_id)
);

comment on table support_ticket_viewers is
    'Heartbeat from the agent ticket view. A row seen within 60 seconds renders the "X is replying to this ticket" banner. Upgradeable to Realtime presence with no schema change.';

create index if not exists support_ticket_viewers_recent_idx
    on support_ticket_viewers (ticket_id, last_seen_at desc);

-- -----------------------------------------------------------------------------
-- 6. support_email_threads — the reply-address token
-- -----------------------------------------------------------------------------

create table if not exists support_email_threads (
    id            uuid primary key default gen_random_uuid(),
    ticket_id     uuid not null references support_tickets (id) on delete cascade,
    reply_token   text not null,
    created_at    timestamptz not null default now(),
    constraint support_email_threads_token_unique unique (reply_token),
    constraint support_email_threads_ticket_unique unique (ticket_id),
    constraint support_email_threads_token_shape check (reply_token ~ '^[a-z0-9]{16,48}$')
);

comment on table support_email_threads is
    'Per-ticket token used in the outbound Reply-To (support+t{token}@tenant-domain). Threading survives mail clients that strip In-Reply-To/References.';

create or replace function support_ensure_reply_token(ticket uuid)
returns text
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
    v_token text;
begin
    select reply_token into v_token from support_email_threads where ticket_id = ticket;
    if v_token is not null then
        return v_token;
    end if;

    v_token := lower(encode(gen_random_bytes(12), 'hex'));

    insert into support_email_threads (ticket_id, reply_token)
    values (ticket, v_token)
    on conflict (ticket_id) do nothing;

    select reply_token into v_token from support_email_threads where ticket_id = ticket;
    return v_token;
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Message triggers — visibility, denormalisation, first-response stamping
-- -----------------------------------------------------------------------------

create or replace function support_message_before_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_org uuid;
begin
    select owning_organization_id into v_org from support_tickets where id = new.ticket_id;
    if v_org is null then
        raise exception 'support_ticket_messages: ticket % does not exist', new.ticket_id;
    end if;

    new.owning_organization_id := v_org;

    -- Visibility is derived, never trusted from input. A private note that
    -- leaks to a requester is the worst bug this module can have.
    new.visible_to_requester := (new.message_type in ('public_reply', 'csat_request'));

    if new.sent_at is null then
        new.sent_at := now();
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_messages_before_insert on support_ticket_messages;
create trigger trg_support_messages_before_insert
    before insert on support_ticket_messages
    for each row execute function support_message_before_insert();

create or replace function support_message_before_update()
returns trigger
language plpgsql
as $$
begin
    new.updated_at := now();
    new.visible_to_requester := (new.message_type in ('public_reply', 'csat_request'));
    return new;
end;
$$;

drop trigger if exists trg_support_messages_before_update on support_ticket_messages;
create trigger trg_support_messages_before_update
    before update on support_ticket_messages
    for each row execute function support_message_before_update();

-- Roll the message up onto the ticket: first response, last reply stamps, and
-- the pending/open status flip that every help desk expects.
create or replace function support_message_after_insert()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_ticket support_tickets%rowtype;
begin
    select * into v_ticket from support_tickets where id = new.ticket_id;

    if new.message_type = 'public_reply' and new.direction = 'outbound' then
        update support_tickets
           set first_responded_at = coalesce(first_responded_at, new.sent_at),
               last_agent_reply_at = new.sent_at,
               -- An agent replying to a new/open ticket puts the ball in the
               -- customer's court; terminal states are left alone.
               status = case
                            when status in ('new', 'open') then 'pending_customer'::support_ticket_status
                            else status
                        end
         where id = new.ticket_id;

        if v_ticket.first_responded_at is null then
            update support_ticket_messages
               set is_first_response = true
             where id = new.id;
        end if;
    end if;

    if new.direction = 'inbound' then
        update support_tickets
           set last_requester_reply_at = new.sent_at,
               -- A customer reply reopens the conversation.
               status = case
                            when status in ('pending_customer', 'resolved') then 'open'::support_ticket_status
                            when status = 'closed' then 'open'::support_ticket_status
                            else status
                        end
         where id = new.ticket_id;
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_messages_after_insert on support_ticket_messages;
create trigger trg_support_messages_after_insert
    after insert on support_ticket_messages
    for each row execute function support_message_after_insert();

drop trigger if exists trg_support_canned_touch on support_canned_responses;
create trigger trg_support_canned_touch
    before update on support_canned_responses
    for each row execute function support_touch_updated_at();

-- -----------------------------------------------------------------------------
-- 8. Row-Level Security
-- -----------------------------------------------------------------------------

alter table support_ticket_messages   enable row level security;
alter table support_attachments       enable row level security;
alter table support_canned_responses  enable row level security;
alter table support_ticket_viewers    enable row level security;
alter table support_email_threads     enable row level security;

-- Agents see everything on their desk; requesters see only public replies.
drop policy if exists support_ticket_messages_agent on support_ticket_messages;
create policy support_ticket_messages_agent on support_ticket_messages
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id));

drop policy if exists support_ticket_messages_requester_read on support_ticket_messages;
create policy support_ticket_messages_requester_read on support_ticket_messages
    for select
    using (visible_to_requester and support_ticket_access(ticket_id));

drop policy if exists support_ticket_messages_requester_reply on support_ticket_messages;
create policy support_ticket_messages_requester_reply on support_ticket_messages
    for insert
    with check (
        message_type = 'public_reply'
        and direction = 'inbound'
        and support_ticket_access(ticket_id)
        and exists (
            select 1 from support_tickets t
            where t.id = ticket_id and t.requester_profile_id = my_profile_id()
        )
    );

drop policy if exists support_attachments_agent on support_attachments;
create policy support_attachments_agent on support_attachments
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id));

drop policy if exists support_attachments_requester_read on support_attachments;
create policy support_attachments_requester_read on support_attachments
    for select
    using (
        support_ticket_access(ticket_id)
        and (
            message_id is null
            or exists (
                select 1 from support_ticket_messages m
                where m.id = message_id and m.visible_to_requester
            )
        )
    );

drop policy if exists support_canned_responses_desk on support_canned_responses;
create policy support_canned_responses_desk on support_canned_responses
    for all
    using (
        owning_organization_id = auth_org_id()
        and (desk_id is null or support_desk_access(desk_id))
    )
    with check (
        owning_organization_id = auth_org_id()
        and (desk_id is null or support_desk_access(desk_id))
    );

drop policy if exists support_ticket_viewers_agent on support_ticket_viewers;
create policy support_ticket_viewers_agent on support_ticket_viewers
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id) and profile_id = my_profile_id());

drop policy if exists support_email_threads_agent on support_email_threads;
create policy support_email_threads_agent on support_email_threads
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id));

-- -----------------------------------------------------------------------------
-- 9. Grants
-- -----------------------------------------------------------------------------

grant select, insert, update, delete on
    support_ticket_messages,
    support_attachments,
    support_canned_responses,
    support_ticket_viewers,
    support_email_threads
to authenticated;

grant execute on function support_ensure_reply_token(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- 10. Seed — canned responses for the platform desk
-- -----------------------------------------------------------------------------

do $$
declare
    v_platform_id uuid;
    v_desk_id     uuid;
    v_owner_id    uuid;
begin
    select id into v_platform_id from organizations where type = 'platform' limit 1;
    select id into v_desk_id from support_desks
     where organization_id = v_platform_id and key = 'platform-support';
    select id into v_owner_id from profiles
     where organization_id = v_platform_id and role = 'bespokelms_owner' order by created_at limit 1;

    if v_desk_id is null then
        return;
    end if;

    insert into support_canned_responses
        (owning_organization_id, desk_id, shortcut, title, body_html, created_by)
    values
        (v_platform_id, v_desk_id, 'ack',
         'Acknowledge receipt',
         '<p>Thanks for getting in touch. We have your request and will come back to you shortly.</p>',
         v_owner_id),
        (v_platform_id, v_desk_id, 'need-info',
         'Ask for more detail',
         '<p>To get to the bottom of this we need a little more detail:</p><ul><li>What were you doing when it happened?</li><li>Which browser or device were you using?</li><li>Roughly what time did it occur?</li></ul>',
         v_owner_id),
        (v_platform_id, v_desk_id, 'password',
         'Password reset guidance',
         '<p>You can reset your password from the sign-in page using the <strong>Forgotten your password?</strong> link. The email arrives within a few minutes; check your junk folder if it does not.</p>',
         v_owner_id),
        (v_platform_id, v_desk_id, 'resolved',
         'Confirm resolution',
         '<p>This should now be sorted. We are marking the ticket resolved, but reply here any time and it reopens automatically.</p>',
         v_owner_id)
    on conflict (owning_organization_id, shortcut) do nothing;
end;
$$;

commit;

-- =============================================================================
-- 11. Supabase Storage — the private `support-attachments` bucket
--
-- No-op on a plain PostgreSQL instance (the storage schema is Supabase-only),
-- so this file replays cleanly in local validation.
--
-- Double enforcement #2: the storage policy keys on the same
-- {organization_id}/ path prefix that the CHECK constraint above enforces.
-- Objects are only ever served through short-lived signed URLs.
-- =============================================================================

do $$
begin
    if not exists (select 1 from pg_namespace where nspname = 'storage') then
        raise notice '094: storage schema absent (local validation) — skipping bucket setup';
        return;
    end if;

    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values (
        'support-attachments', 'support-attachments', false, 26214400,
        array[
            'image/png', 'image/jpeg', 'image/gif', 'image/webp',
            'application/pdf', 'text/plain', 'text/csv',
            'application/zip',
            'application/msword',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'application/vnd.ms-excel',
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
        ]
    )
    on conflict (id) do nothing;

    execute $p$
        drop policy if exists support_attachments_read on storage.objects;
        create policy support_attachments_read on storage.objects
            for select
            using (
                bucket_id = 'support-attachments'
                and exists (
                    select 1 from public.support_attachments a
                    where a.storage_path = storage.objects.name
                      and public.support_ticket_access(a.ticket_id)
                )
            );

        drop policy if exists support_attachments_write on storage.objects;
        create policy support_attachments_write on storage.objects
            for insert
            with check (
                bucket_id = 'support-attachments'
                and (storage.foldername(name))[1] = public.auth_org_id()::text
            );

        drop policy if exists support_attachments_delete on storage.objects;
        create policy support_attachments_delete on storage.objects
            for delete
            using (
                bucket_id = 'support-attachments'
                and exists (
                    select 1 from public.support_attachments a
                    where a.storage_path = storage.objects.name
                      and public.support_ticket_manage(a.ticket_id)
                )
            );
    $p$;
end;
$$;
