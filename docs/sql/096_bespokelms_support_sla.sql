-- =============================================================================
-- 096_bespokelms_support_sla.sql
-- BespokeLMS — Support Desk, Phase 2: SLA policies, targets and the clock.
--
-- Migration name (apply_migration): bespokelms_support_sla_096
-- Depends on: 092, 093, 094.
--
--   * support_sla_policies   — which tickets a policy applies to (conditions
--                              jsonb), and which calendar it runs on
--   * support_sla_targets    — per-priority first-response / next-response /
--                              resolution minutes, plus the escalation warning
--   * support_ticket_sla     — the per-ticket clock (1:1), including what is
--                              LEFT when the clock is paused
--   * support_sla_pause_log  — why and for how long the clock stopped
--
-- The two functions that do the real work:
--   business_minutes_between(cal, from, to) — operational minutes in a span
--   business_hours_add(cal, from, minutes)  — "now + N working minutes"
--
-- Both honour week_hours (per-day windows, split shifts supported), holidays,
-- and the calendar's own timezone. Everything else in this file is bookkeeping
-- around those two.
--
-- Clock model (proposal §6.4, the hybrid): targets are STAMPED on write by a
-- trigger, so the due dates are real columns that index and sort cheaply. A
-- scheduled sweep only has to find rows already past their stamp — it never
-- recomputes the calendar. Pausing does not adjust a due date arithmetically;
-- it records the minutes REMAINING, and resuming re-derives the due date from
-- "now + remaining". That way a ticket parked over a weekend resumes with the
-- time it actually had left, rather than accumulating rounding drift.
-- =============================================================================

begin;

-- -----------------------------------------------------------------------------
-- 1. Calendar arithmetic
-- -----------------------------------------------------------------------------

-- Operational minutes between two instants, per a business calendar.
-- Returns 0 when to <= from. Walks day by day in the calendar's timezone.
create or replace function business_minutes_between(cal uuid, from_ts timestamptz, to_ts timestamptz)
returns integer
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
    v_tz        text;
    v_week      jsonb;
    v_day       date;
    v_last      date;
    v_dow       text;
    v_window    jsonb;
    v_open      timestamptz;
    v_close     timestamptz;
    v_from      timestamptz;
    v_to        timestamptz;
    v_total     numeric := 0;
    v_guard     integer := 0;
begin
    if cal is null or to_ts is null or from_ts is null or to_ts <= from_ts then
        return 0;
    end if;

    select timezone, week_hours into v_tz, v_week from business_calendars where id = cal;

    if v_tz is null then
        -- No calendar: fall back to wall-clock, which is at least honest.
        return greatest(0, (extract(epoch from (to_ts - from_ts)) / 60)::integer);
    end if;

    v_day  := (from_ts at time zone v_tz)::date;
    v_last := (to_ts at time zone v_tz)::date;

    while v_day <= v_last loop
        v_guard := v_guard + 1;
        exit when v_guard > 3660;   -- ~10 years; a runaway span is a bug, not a wait

        if not exists (
            select 1 from business_calendar_holidays h
            where h.calendar_id = cal
              and (h.holiday_date = v_day
                   or (h.is_recurring_annually
                       and extract(month from h.holiday_date) = extract(month from v_day)
                       and extract(day from h.holiday_date) = extract(day from v_day)))
        ) then
            v_dow := lower(to_char(v_day, 'dy'));

            for v_window in select * from jsonb_array_elements(coalesce(v_week -> v_dow, '[]'::jsonb))
            loop
                v_open  := ((v_day::text || ' ' || (v_window ->> 0))::timestamp) at time zone v_tz;
                v_close := ((v_day::text || ' ' || (v_window ->> 1))::timestamp) at time zone v_tz;

                v_from := greatest(v_open, from_ts);
                v_to   := least(v_close, to_ts);

                if v_to > v_from then
                    v_total := v_total + extract(epoch from (v_to - v_from)) / 60;
                end if;
            end loop;
        end if;

        v_day := v_day + 1;
    end loop;

    return floor(v_total)::integer;
end;
$$;

comment on function business_minutes_between(uuid, timestamptz, timestamptz) is
    'Operational minutes between two instants for a business calendar, honouring per-day windows, split shifts, holidays and the calendar timezone.';

-- "from_ts plus N operational minutes". The inverse of the function above, and
-- the one that produces every due date in this module.
create or replace function business_hours_add(cal uuid, from_ts timestamptz, minutes integer)
returns timestamptz
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
    v_tz        text;
    v_week      jsonb;
    v_day       date;
    v_dow       text;
    v_window    jsonb;
    v_open      timestamptz;
    v_close     timestamptz;
    v_from      timestamptz;
    v_available numeric;
    v_remaining numeric;
    v_guard     integer := 0;
begin
    if minutes is null or minutes <= 0 then
        return from_ts;
    end if;

    select timezone, week_hours into v_tz, v_week from business_calendars where id = cal;

    if v_tz is null then
        return from_ts + make_interval(mins => minutes);
    end if;

    v_remaining := minutes;
    v_day := (from_ts at time zone v_tz)::date;

    loop
        v_guard := v_guard + 1;
        -- A calendar with no open windows at all would otherwise spin forever.
        -- Give up after ~2 years and fall back to wall-clock so a misconfigured
        -- calendar degrades to a wrong-but-finite answer instead of a hung write.
        if v_guard > 730 then
            return from_ts + make_interval(mins => minutes);
        end if;

        if not exists (
            select 1 from business_calendar_holidays h
            where h.calendar_id = cal
              and (h.holiday_date = v_day
                   or (h.is_recurring_annually
                       and extract(month from h.holiday_date) = extract(month from v_day)
                       and extract(day from h.holiday_date) = extract(day from v_day)))
        ) then
            v_dow := lower(to_char(v_day, 'dy'));

            for v_window in select * from jsonb_array_elements(coalesce(v_week -> v_dow, '[]'::jsonb))
            loop
                v_open  := ((v_day::text || ' ' || (v_window ->> 0))::timestamp) at time zone v_tz;
                v_close := ((v_day::text || ' ' || (v_window ->> 1))::timestamp) at time zone v_tz;

                v_from := greatest(v_open, from_ts);

                if v_close > v_from then
                    v_available := extract(epoch from (v_close - v_from)) / 60;

                    if v_available >= v_remaining then
                        return v_from + make_interval(mins => v_remaining::integer);
                    end if;

                    v_remaining := v_remaining - v_available;
                end if;
            end loop;
        end if;

        v_day := v_day + 1;
    end loop;
end;
$$;

comment on function business_hours_add(uuid, timestamptz, integer) is
    'The instant N operational minutes after from_ts, per a business calendar. Every SLA due date in the module comes from here.';

-- -----------------------------------------------------------------------------
-- 2. Policies and targets
-- -----------------------------------------------------------------------------

create table if not exists support_sla_policies (
    id                       uuid primary key default gen_random_uuid(),
    owning_organization_id   uuid not null references organizations (id) on delete cascade,
    desk_id                  uuid not null references support_desks (id) on delete cascade,
    name                     text not null,
    description              text,
    -- Which tickets this policy claims. Keys are optional; a key that is
    -- absent means "any". e.g. {"priority":["high","urgent"],"ticket_type":["incident"]}
    conditions               jsonb not null default '{}'::jsonb,
    business_calendar_id     uuid references business_calendars (id) on delete set null,
    is_default               boolean not null default false,
    sort_order               integer not null default 0,
    is_active                boolean not null default true,
    created_by               uuid references profiles (id) on delete set null,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    constraint support_sla_policies_name_unique unique (desk_id, name)
);

comment on table support_sla_policies is
    'Ordered rules deciding which SLA a ticket gets. First match by sort_order wins; the default policy catches everything else.';

create unique index if not exists support_sla_policies_one_default
    on support_sla_policies (desk_id)
    where is_default;

create table if not exists support_sla_targets (
    id                       uuid primary key default gen_random_uuid(),
    policy_id                uuid not null references support_sla_policies (id) on delete cascade,
    priority                 support_priority not null,
    first_response_minutes   integer,
    next_response_minutes    integer,
    resolution_minutes       integer,
    escalate_after_percent   integer not null default 80,
    escalate_to_profile_id   uuid references profiles (id) on delete set null,
    operational_hours_only   boolean not null default true,
    created_at               timestamptz not null default now(),
    updated_at               timestamptz not null default now(),
    constraint support_sla_targets_unique unique (policy_id, priority),
    constraint support_sla_targets_positive check (
        (first_response_minutes is null or first_response_minutes > 0)
        and (next_response_minutes is null or next_response_minutes > 0)
        and (resolution_minutes is null or resolution_minutes > 0)
    ),
    constraint support_sla_targets_percent check (escalate_after_percent between 1 and 100)
);

-- -----------------------------------------------------------------------------
-- 3. The per-ticket clock
-- -----------------------------------------------------------------------------

create table if not exists support_ticket_sla (
    ticket_id                       uuid primary key references support_tickets (id) on delete cascade,
    owning_organization_id          uuid not null references organizations (id) on delete cascade,
    policy_id                       uuid references support_sla_policies (id) on delete set null,
    calendar_id                     uuid references business_calendars (id) on delete set null,
    first_response_due_at           timestamptz,
    next_response_due_at            timestamptz,
    resolution_due_at               timestamptz,
    first_response_breached_at      timestamptz,
    resolution_breached_at          timestamptz,
    -- What is left on each clock while it is paused. Null when running.
    remaining_first_response_minutes integer,
    remaining_resolution_minutes    integer,
    paused_at                       timestamptz,
    paused_total_minutes            integer not null default 0,
    computed_at                     timestamptz not null default now()
);

create index if not exists support_ticket_sla_resolution_idx
    on support_ticket_sla (resolution_due_at)
    where resolution_breached_at is null and paused_at is null;

create index if not exists support_ticket_sla_first_response_idx
    on support_ticket_sla (first_response_due_at)
    where first_response_breached_at is null and paused_at is null;

create table if not exists support_sla_pause_log (
    id            uuid primary key default gen_random_uuid(),
    ticket_id     uuid not null references support_tickets (id) on delete cascade,
    paused_at     timestamptz not null default now(),
    resumed_at    timestamptz,
    reason        text not null,
    minutes       integer,
    constraint support_sla_pause_log_reason_valid check (
        reason in ('pending_customer', 'pending_third_party', 'on_hold')
    )
);

create index if not exists support_sla_pause_log_open_idx
    on support_sla_pause_log (ticket_id)
    where resumed_at is null;

-- -----------------------------------------------------------------------------
-- 4. Policy matching and stamping
-- -----------------------------------------------------------------------------

-- First policy whose conditions the ticket satisfies, else the desk default.
create or replace function support_match_sla_policy(ticket uuid)
returns uuid
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
    v_t      support_tickets%rowtype;
    v_policy record;
begin
    select * into v_t from support_tickets where id = ticket;
    if v_t.id is null then
        return null;
    end if;

    for v_policy in
        select id, conditions
          from support_sla_policies
         where desk_id = v_t.desk_id and is_active and not is_default
         order by sort_order, created_at
    loop
        if (v_policy.conditions ? 'priority')
           and not (v_policy.conditions -> 'priority' ? v_t.priority::text) then
            continue;
        end if;

        if (v_policy.conditions ? 'ticket_type')
           and not (v_policy.conditions -> 'ticket_type' ? v_t.ticket_type::text) then
            continue;
        end if;

        if (v_policy.conditions ? 'channel')
           and not (v_policy.conditions -> 'channel' ? v_t.channel::text) then
            continue;
        end if;

        if (v_policy.conditions ? 'group_id')
           and (v_t.group_id is null
                or not (v_policy.conditions -> 'group_id' ? v_t.group_id::text)) then
            continue;
        end if;

        return v_policy.id;
    end loop;

    return (
        select id from support_sla_policies
         where desk_id = v_t.desk_id and is_active and is_default
         limit 1
    );
end;
$$;

-- Compute (or recompute) the clock for a ticket.
create or replace function support_stamp_sla(ticket uuid)
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
    v_t        support_tickets%rowtype;
    v_policy   uuid;
    v_cal      uuid;
    v_target   support_sla_targets%rowtype;
    v_start    timestamptz;
    v_first    timestamptz;
    v_res      timestamptz;
begin
    select * into v_t from support_tickets where id = ticket;
    if v_t.id is null then
        return;
    end if;

    v_policy := support_match_sla_policy(ticket);

    if v_policy is null then
        return;   -- desk has no SLA configured; nothing to promise
    end if;

    select coalesce(p.business_calendar_id, d.business_calendar_id)
      into v_cal
      from support_sla_policies p
      join support_desks d on d.id = p.desk_id
     where p.id = v_policy;

    select * into v_target
      from support_sla_targets
     where policy_id = v_policy and priority = v_t.priority;

    if v_target.id is null then
        return;
    end if;

    v_start := v_t.created_at;

    if v_target.operational_hours_only then
        v_first := case when v_target.first_response_minutes is null then null
                        else business_hours_add(v_cal, v_start, v_target.first_response_minutes) end;
        v_res   := case when v_target.resolution_minutes is null then null
                        else business_hours_add(v_cal, v_start, v_target.resolution_minutes) end;
    else
        v_first := case when v_target.first_response_minutes is null then null
                        else v_start + make_interval(mins => v_target.first_response_minutes) end;
        v_res   := case when v_target.resolution_minutes is null then null
                        else v_start + make_interval(mins => v_target.resolution_minutes) end;
    end if;

    insert into support_ticket_sla (
        ticket_id, owning_organization_id, policy_id, calendar_id,
        first_response_due_at, resolution_due_at, computed_at
    )
    values (ticket, v_t.owning_organization_id, v_policy, v_cal, v_first, v_res, now())
    on conflict (ticket_id) do update
        set policy_id = excluded.policy_id,
            calendar_id = excluded.calendar_id,
            first_response_due_at = case
                when support_ticket_sla.first_response_breached_at is not null
                     or support_ticket_sla.first_response_due_at is null
                then excluded.first_response_due_at
                -- A first-response promise already made is not re-promised just
                -- because someone changed the priority afterwards.
                else support_ticket_sla.first_response_due_at
            end,
            resolution_due_at = excluded.resolution_due_at,
            computed_at = now();

    -- Mirror onto the ticket so queue sorting and the partial index in 093 work
    -- without a join.
    update support_tickets
       set first_response_due_at = v_first,
           resolution_due_at = v_res
     where id = ticket;
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Pause and resume
-- -----------------------------------------------------------------------------

create or replace function support_pause_sla(ticket uuid, reason text)
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
    v_sla support_ticket_sla%rowtype;
begin
    select * into v_sla from support_ticket_sla where ticket_id = ticket;

    if v_sla.ticket_id is null or v_sla.paused_at is not null then
        return;
    end if;

    update support_ticket_sla
       set paused_at = now(),
           remaining_first_response_minutes = case
               when first_response_due_at is null or first_response_breached_at is not null then null
               else business_minutes_between(calendar_id, now(), first_response_due_at)
           end,
           remaining_resolution_minutes = case
               when resolution_due_at is null or resolution_breached_at is not null then null
               else business_minutes_between(calendar_id, now(), resolution_due_at)
           end
     where ticket_id = ticket;

    insert into support_sla_pause_log (ticket_id, reason) values (ticket, reason);
end;
$$;

create or replace function support_resume_sla(ticket uuid)
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
    v_sla     support_ticket_sla%rowtype;
    v_minutes integer;
begin
    select * into v_sla from support_ticket_sla where ticket_id = ticket;

    if v_sla.ticket_id is null or v_sla.paused_at is null then
        return;
    end if;

    v_minutes := business_minutes_between(v_sla.calendar_id, v_sla.paused_at, now());

    update support_ticket_sla
       set paused_at = null,
           paused_total_minutes = paused_total_minutes + coalesce(v_minutes, 0),
           -- Re-derive from "now + what was left", so a ticket parked over a
           -- weekend resumes with the time it actually had.
           first_response_due_at = case
               when remaining_first_response_minutes is null then first_response_due_at
               else business_hours_add(calendar_id, now(), remaining_first_response_minutes)
           end,
           resolution_due_at = case
               when remaining_resolution_minutes is null then resolution_due_at
               else business_hours_add(calendar_id, now(), remaining_resolution_minutes)
           end,
           remaining_first_response_minutes = null,
           remaining_resolution_minutes = null,
           computed_at = now()
     where ticket_id = ticket;

    update support_sla_pause_log
       set resumed_at = now(),
           minutes = coalesce(v_minutes, 0)
     where ticket_id = ticket and resumed_at is null;

    update support_tickets t
       set first_response_due_at = s.first_response_due_at,
           resolution_due_at = s.resolution_due_at
      from support_ticket_sla s
     where s.ticket_id = t.id and t.id = ticket;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Triggers — stamp on create, pause/resume on status, stop on first response
-- -----------------------------------------------------------------------------

create or replace function support_ticket_sla_sync()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_pausing constant text[] := array['pending_customer', 'pending_third_party', 'on_hold'];
begin
    if tg_op = 'INSERT' then
        perform support_stamp_sla(new.id);
        return new;
    end if;

    -- First response answers the first-response clock for good.
    if new.first_responded_at is not null and old.first_responded_at is null then
        update support_ticket_sla
           set first_response_breached_at = case
                   when first_response_due_at is not null
                        and new.first_responded_at > first_response_due_at
                   then new.first_responded_at
                   else first_response_breached_at
               end,
               remaining_first_response_minutes = null
         where ticket_id = new.id;
    end if;

    if new.status is distinct from old.status then
        -- Cast to text: support_ticket_status is an enum and has no operator
        -- against a text[]. Without the cast every status change raises.
        if new.status::text = any (v_pausing) and not (old.status::text = any (v_pausing)) then
            perform support_pause_sla(new.id, new.status::text);
        elsif old.status::text = any (v_pausing) and not (new.status::text = any (v_pausing)) then
            perform support_resume_sla(new.id);
        end if;

        -- Resolution stops the resolution clock; a breach is recorded once.
        if new.status in ('resolved', 'closed') and old.status not in ('resolved', 'closed') then
            update support_ticket_sla
               set resolution_breached_at = case
                       when resolution_due_at is not null and now() > resolution_due_at
                       then now()
                       else resolution_breached_at
                   end,
                   paused_at = null,
                   remaining_resolution_minutes = null
             where ticket_id = new.id;
        end if;
    end if;

    -- A priority change re-promises the resolution clock (never the first
    -- response — see support_stamp_sla).
    if new.priority is distinct from old.priority then
        perform support_stamp_sla(new.id);
    end if;

    return new;
end;
$$;

drop trigger if exists trg_support_tickets_sla on support_tickets;
create trigger trg_support_tickets_sla
    after insert or update on support_tickets
    for each row execute function support_ticket_sla_sync();

-- -----------------------------------------------------------------------------
-- 7. The breach sweep (called by the Laravel scheduler every few minutes)
-- -----------------------------------------------------------------------------

create or replace function support_sweep_sla_breaches()
returns integer
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
    v_count integer := 0;
    r       record;
begin
    for r in
        select s.ticket_id, t.reference, s.first_response_due_at, s.resolution_due_at,
               s.first_response_breached_at, s.resolution_breached_at
          from support_ticket_sla s
          join support_tickets t on t.id = s.ticket_id
         where s.paused_at is null
           and t.status not in ('resolved', 'closed', 'spam', 'deleted')
           and (
                 (s.first_response_breached_at is null
                  and s.first_response_due_at is not null
                  and s.first_response_due_at < now()
                  and t.first_responded_at is null)
              or (s.resolution_breached_at is null
                  and s.resolution_due_at is not null
                  and s.resolution_due_at < now())
           )
    loop
        update support_ticket_sla
           set first_response_breached_at = case
                   when first_response_breached_at is null
                        and first_response_due_at is not null
                        and first_response_due_at < now()
                   then now() else first_response_breached_at end,
               resolution_breached_at = case
                   when resolution_breached_at is null
                        and resolution_due_at is not null
                        and resolution_due_at < now()
                   then now() else resolution_breached_at end
         where ticket_id = r.ticket_id;

        insert into support_ticket_events (ticket_id, event_type, to_value, note)
        values (r.ticket_id, 'sla_breached', r.reference, 'Detected by the scheduled sweep.');

        v_count := v_count + 1;
    end loop;

    return v_count;
end;
$$;

comment on function support_sweep_sla_breaches() is
    'Marks newly breached clocks and writes a ticket event. Idempotent: a ticket already flagged is skipped, so running it twice is harmless.';

-- -----------------------------------------------------------------------------
-- 8. RLS and grants
-- -----------------------------------------------------------------------------

alter table support_sla_policies   enable row level security;
alter table support_sla_targets    enable row level security;
alter table support_ticket_sla     enable row level security;
alter table support_sla_pause_log  enable row level security;

drop policy if exists support_sla_policies_read on support_sla_policies;
create policy support_sla_policies_read on support_sla_policies
    for select using (support_desk_access(desk_id));

drop policy if exists support_sla_policies_write on support_sla_policies;
create policy support_sla_policies_write on support_sla_policies
    for all
    using (support_desk_admin(desk_id))
    with check (support_desk_admin(desk_id));

drop policy if exists support_sla_targets_read on support_sla_targets;
create policy support_sla_targets_read on support_sla_targets
    for select using (exists (
        select 1 from support_sla_policies p
        where p.id = policy_id and support_desk_access(p.desk_id)
    ));

drop policy if exists support_sla_targets_write on support_sla_targets;
create policy support_sla_targets_write on support_sla_targets
    for all
    using (exists (select 1 from support_sla_policies p where p.id = policy_id and support_desk_admin(p.desk_id)))
    with check (exists (select 1 from support_sla_policies p where p.id = policy_id and support_desk_admin(p.desk_id)));

drop policy if exists support_ticket_sla_read on support_ticket_sla;
create policy support_ticket_sla_read on support_ticket_sla
    for select using (support_ticket_access(ticket_id));

drop policy if exists support_ticket_sla_write on support_ticket_sla;
create policy support_ticket_sla_write on support_ticket_sla
    for all
    using (support_ticket_manage(ticket_id))
    with check (support_ticket_manage(ticket_id));

drop policy if exists support_sla_pause_log_read on support_sla_pause_log;
create policy support_sla_pause_log_read on support_sla_pause_log
    for select using (support_ticket_access(ticket_id));

grant select, insert, update, delete on
    support_sla_policies, support_sla_targets, support_ticket_sla, support_sla_pause_log
to authenticated;

grant execute on function business_minutes_between(uuid, timestamptz, timestamptz) to authenticated;
grant execute on function business_hours_add(uuid, timestamptz, integer)            to authenticated;
grant execute on function support_match_sla_policy(uuid)                            to authenticated;
grant execute on function support_stamp_sla(uuid)                                   to authenticated;
grant execute on function support_pause_sla(uuid, text)                             to authenticated;
grant execute on function support_resume_sla(uuid)                                  to authenticated;
grant execute on function support_sweep_sla_breaches()                              to authenticated;

-- -----------------------------------------------------------------------------
-- 9. Seed — a default policy for the platform desk
-- -----------------------------------------------------------------------------

do $$
declare
    v_desk   uuid;
    v_org    uuid;
    v_cal    uuid;
    v_policy uuid;
begin
    select d.id, d.organization_id, d.business_calendar_id
      into v_desk, v_org, v_cal
      from support_desks d
      join organizations o on o.id = d.organization_id
     where o.type = 'platform' and d.key = 'platform-support';

    if v_desk is null then
        return;
    end if;

    insert into support_sla_policies (owning_organization_id, desk_id, name, description,
                                      business_calendar_id, is_default, sort_order)
    values (v_org, v_desk, 'Standard', 'Applies to any ticket without a more specific policy.',
            v_cal, true, 100)
    on conflict (desk_id, name) do nothing
    returning id into v_policy;

    if v_policy is null then
        select id into v_policy from support_sla_policies where desk_id = v_desk and name = 'Standard';
    end if;

    insert into support_sla_targets (policy_id, priority, first_response_minutes, resolution_minutes)
    values
        (v_policy, 'urgent',  30,   240),    -- 30 min / 4 working hours
        (v_policy, 'high',    120,  480),    -- 2 h / 1 working day
        (v_policy, 'medium',  480,  2400),   -- 1 day / 5 working days
        (v_policy, 'low',     960,  4800)    -- 2 days / 10 working days
    on conflict (policy_id, priority) do nothing;
end;
$$;

commit;
