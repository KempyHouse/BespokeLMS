-- Validation harness for migrations 092/093/094/095.
-- Runs against a throwaway PostgreSQL instance seeded with _shim.sql.
-- Not part of the migration series — never applied to Supabase.

\set ON_ERROR_STOP on

-- =============================== 092 ========================================
do $$
declare v_desk uuid; v_ref text;
begin
    select id into v_desk from support_desks where key = 'platform-support';
    if v_desk is null then raise exception 'FAIL 092: platform desk not seeded'; end if;

    v_ref := support_next_reference(v_desk);
    if v_ref <> 'BLMS-1' then raise exception 'FAIL 092: first reference % (expected BLMS-1)', v_ref; end if;
    if support_next_reference(v_desk) <> 'BLMS-2' then raise exception 'FAIL 092: reference not incrementing'; end if;

    if not exists (select 1 from support_desks d join support_ticket_groups g on g.id = d.default_group_id
                   where d.id = v_desk and g.key = 'general') then
        raise exception 'FAIL 092: default group not wired'; end if;

    if not exists (select 1 from support_agents where desk_id = v_desk and agent_role = 'admin') then
        raise exception 'FAIL 092: owner not seeded as agent'; end if;

    if (select count(*) from tenant_modules
        where module_key in ('support_desk','knowledge_base','support_portal')) <> 3 then
        raise exception 'FAIL 092: three module keys not seeded'; end if;

    begin
        insert into support_desks (organization_id, key, name, reference_prefix)
        values ('aaaaaaaa-0000-4000-8000-000000000001', 'nope', 'Nope', 'NOPE');
        raise exception 'FAIL 092: a client organisation was allowed to own a desk';
    exception when others then
        if position('only platform or operator' in sqlerrm) = 0 then raise; end if;
    end;

    begin
        insert into support_agents (desk_id, owning_organization_id, profile_id)
        values (v_desk, 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c', 'cccccccc-0000-4000-8000-000000000004');
        raise exception 'FAIL 092: cross-organisation agent accepted';
    exception when others then
        if position('cannot agent on a desk' in sqlerrm) = 0 then raise; end if;
    end;

    begin
        insert into support_access_grants (granted_to_profile_id, desk_id, reason, expires_at)
        values ('06313023-2de7-455f-8b05-1a4bf88a03eb', v_desk,
                'a reason long enough to pass the check', now() + interval '48 hours');
        raise exception 'FAIL 092: 48-hour break-glass window accepted';
    exception when others then
        if position('max_window' in sqlerrm) = 0 then raise; end if;
    end;

    begin
        insert into support_access_grants (granted_to_profile_id, desk_id, reason, expires_at)
        values ('06313023-2de7-455f-8b05-1a4bf88a03eb', v_desk, 'because', now() + interval '1 hour');
        raise exception 'FAIL 092: unreasoned break-glass accepted';
    exception when others then
        if position('reason_meaningful' in sqlerrm) = 0 then raise; end if;
    end;

    raise notice '092 foundation .............. PASS';
end $$;

-- =============================== 093 ========================================
do $$
declare v_desk uuid; v_group uuid; v_t uuid; v_ref text; v_st text; v_n integer;
begin
    select id, default_group_id into v_desk, v_group from support_desks where key = 'platform-support';

    insert into support_tickets (desk_id, subject, requester_profile_id, requester_organization_id,
                                 channel, group_id, created_by)
    values (v_desk, 'Cannot download my certificate', '1caa7e4d-ab84-4cee-9ab4-779a18ab3748',
            '88c98875-7f24-4534-a329-f7930b58cebe', 'email', v_group, '06313023-2de7-455f-8b05-1a4bf88a03eb')
    returning id, reference into v_t, v_ref;

    if v_ref not like 'BLMS-%' then raise exception 'FAIL 093: reference % not branded', v_ref; end if;
    if (select owning_organization_id from support_tickets where id = v_t)
       <> 'f8bd0282-7e62-4f03-9f63-199a9f7dc35c' then
        raise exception 'FAIL 093: owning organisation not denormalised from the desk'; end if;
    if not exists (select 1 from support_ticket_events where ticket_id = v_t and event_type = 'created') then
        raise exception 'FAIL 093: created event not written'; end if;

    -- an unknown sender is representable without inventing a CRM contact
    insert into support_tickets (desk_id, subject, requester_email, requester_name, channel)
    values (v_desk, 'Pricing question', 'stranger@example.com', 'A Stranger', 'portal');

    begin
        insert into support_tickets (desk_id, subject) values (v_desk, 'Nobody');
        raise exception 'FAIL 093: requester-less ticket accepted';
    exception when others then
        if position('requester_present' in sqlerrm) = 0 then raise; end if;
    end;

    insert into crm_contacts (id, owning_organization_id, first_name, email)
    values ('33333333-0000-4000-8000-000000000001', '88c98875-7f24-4534-a329-f7930b58cebe', 'TPOnly', 'tp@only.com')
    on conflict do nothing;
    begin
        insert into support_tickets (desk_id, subject, requester_contact_id)
        values (v_desk, 'Foreign contact', '33333333-0000-4000-8000-000000000001');
        raise exception 'FAIL 093: another tenant''s CRM contact accepted as requester';
    exception when others then
        if position('does not belong to this desk' in sqlerrm) = 0 then raise; end if;
    end;

    update support_tickets set status = 'resolved' where id = v_t;
    if (select resolved_at from support_tickets where id = v_t) is null then
        raise exception 'FAIL 093: resolved_at not stamped'; end if;

    update support_tickets set status = 'open' where id = v_t;
    select reopened_count into v_n from support_tickets where id = v_t;
    if v_n <> 1 then raise exception 'FAIL 093: reopened_count is %', v_n; end if;
    if (select resolved_at from support_tickets where id = v_t) is not null then
        raise exception 'FAIL 093: resolved_at not cleared on reopen'; end if;
    if not exists (select 1 from support_ticket_events where ticket_id = v_t and event_type = 'reopened') then
        raise exception 'FAIL 093: reopened event not written'; end if;

    update support_tickets set priority = 'urgent',
           assignee_profile_id = 'bbbbbbbb-0000-4000-8000-000000000003' where id = v_t;
    if (select count(*) from support_ticket_events where ticket_id = v_t
        and event_type in ('priority_changed', 'assigned')) <> 2 then
        raise exception 'FAIL 093: priority/assignment events not written'; end if;

    raise notice '093 ticket core ............. PASS';
end $$;

-- =============================== 094 ========================================
do $$
declare v_t uuid; v_m uuid; v_st text; v_tok text; v_org uuid;
begin
    select id into v_t from support_tickets where subject = 'Cannot download my certificate';
    update support_tickets set status = 'new', first_responded_at = null where id = v_t;

    insert into support_ticket_messages (ticket_id, message_type, direction, body_plain,
                                         author_profile_id, visible_to_requester)
    values (v_t, 'private_note', 'internal', 'Checking their enrolment record.',
            '06313023-2de7-455f-8b05-1a4bf88a03eb', true);
    if (select visible_to_requester from support_ticket_messages
        where ticket_id = v_t and message_type = 'private_note') then
        raise exception 'FAIL 094: private note was stored as requester-visible'; end if;

    insert into support_ticket_messages (ticket_id, message_type, direction, body_html, author_profile_id)
    values (v_t, 'public_reply', 'outbound', '<p>Looking into it now.</p>', '06313023-2de7-455f-8b05-1a4bf88a03eb')
    returning id into v_m;

    select status::text into v_st from support_tickets where id = v_t;
    if v_st <> 'pending_customer' then raise exception 'FAIL 094: status after agent reply is %', v_st; end if;
    if (select first_responded_at from support_tickets where id = v_t) is null then
        raise exception 'FAIL 094: first_responded_at not stamped'; end if;
    if not (select is_first_response from support_ticket_messages where id = v_m) then
        raise exception 'FAIL 094: is_first_response not set'; end if;

    insert into support_ticket_messages (ticket_id, message_type, direction, body_plain, author_email)
    values (v_t, 'public_reply', 'inbound', 'Still broken.', 'admin@tp.test');
    select status::text into v_st from support_tickets where id = v_t;
    if v_st <> 'open' then raise exception 'FAIL 094: customer reply did not reopen (status %)', v_st; end if;

    insert into support_ticket_messages (ticket_id, message_type, direction, body_plain, author_profile_id)
    values (v_t, 'public_reply', 'outbound', 'Fixed.', '06313023-2de7-455f-8b05-1a4bf88a03eb');
    if (select count(*) from support_ticket_messages where ticket_id = v_t and is_first_response) <> 1 then
        raise exception 'FAIL 094: more than one message marked first response'; end if;

    v_tok := support_ensure_reply_token(v_t);
    if v_tok <> support_ensure_reply_token(v_t) then raise exception 'FAIL 094: reply token not stable'; end if;

    select owning_organization_id into v_org from support_tickets where id = v_t;
    insert into support_attachments (owning_organization_id, ticket_id, storage_path, file_name, mime_type, byte_size)
    values (v_org, v_t, v_org::text || '/tickets/' || v_t::text || '/abc-screenshot.png',
            'screenshot.png', 'image/png', 4096);
    begin
        insert into support_attachments (owning_organization_id, ticket_id, storage_path, file_name, mime_type, byte_size)
        values (v_org, v_t, 'somewhere-else/evil.png', 'evil.png', 'image/png', 10);
        raise exception 'FAIL 094: attachment escaped the organisation path prefix';
    exception when others then
        if position('path_prefix' in sqlerrm) = 0 then raise; end if;
    end;

    begin
        insert into support_ticket_messages (ticket_id, message_type, direction, body_plain, author_profile_id)
        values (v_t, 'public_reply', 'outbound', '   ', '06313023-2de7-455f-8b05-1a4bf88a03eb');
        raise exception 'FAIL 094: empty message body accepted';
    exception when others then
        if position('body_present' in sqlerrm) = 0 then raise; end if;
    end;

    if (select count(*) from support_canned_responses) < 4 then
        raise exception 'FAIL 094: canned responses not seeded'; end if;

    raise notice '094 conversations ........... PASS';
end $$;

-- =============================== 095 ========================================
do $$
declare v_desk uuid; v_t uuid; v_n integer; v_conf text;
begin
    select id into v_desk from support_desks where key = 'platform-support';

    insert into support_tickets (desk_id, subject, ticket_type, requester_contact_id, account_id,
                                 requester_profile_id, channel)
    values (v_desk, 'Repeated login failures', 'complaint', '22222222-0000-4000-8000-000000000001',
            '11111111-0000-4000-8000-000000000001', '1caa7e4d-ab84-4cee-9ab4-779a18ab3748', 'portal')
    returning id into v_t;

    select count(*) into v_n from crm_activities where ticket_id = v_t;
    if v_n <> 1 then raise exception 'FAIL 095: expected 1 pointer row on create, got %', v_n; end if;

    select confidentiality into v_conf from crm_activities where ticket_id = v_t;
    if v_conf <> 'restricted' then raise exception 'FAIL 095: complaint pointer not restricted (%)', v_conf; end if;
    if (select origin_module from crm_activities where ticket_id = v_t limit 1) <> 'support' then
        raise exception 'FAIL 095: origin_module not support'; end if;
    if (select body from crm_activities where ticket_id = v_t limit 1) is not null then
        raise exception 'FAIL 095: pointer row carries a message body'; end if;

    insert into support_ticket_messages (ticket_id, message_type, direction, body_plain, author_profile_id)
    values (v_t, 'public_reply', 'outbound', 'On it.', '06313023-2de7-455f-8b05-1a4bf88a03eb');
    update support_tickets set status = 'resolved' where id = v_t;
    select count(*) into v_n from crm_activities where ticket_id = v_t;
    if v_n <> 3 then raise exception 'FAIL 095: expected 3 pointer rows, got %', v_n; end if;

    update support_tickets set status = 'open' where id = v_t;
    select count(*) into v_n from crm_activities where ticket_id = v_t;
    if v_n <> 4 then raise exception 'FAIL 095: expected 4 pointer rows after reopen, got %', v_n; end if;

    if exists (select 1 from crm_activities where origin_module not in ('sales', 'support')) then
        raise exception 'FAIL 095: unexpected origin_module value'; end if;

    if (select open_complaints from v_crm_account_support_health
        where account_id = '11111111-0000-4000-8000-000000000001') <> 1 then
        raise exception 'FAIL 095: account support-health view wrong'; end if;

    raise notice '095 timeline lens ........... PASS';
end $$;

-- ======================= cross-tenant isolation ==============================
insert into tenant_modules (organization_id, module_key, enabled, enabled_at)
values ('88c98875-7f24-4534-a329-f7930b58cebe', 'support_desk', true, now())
on conflict do nothing;

insert into business_calendars (owning_organization_id, name, is_default)
values ('88c98875-7f24-4534-a329-f7930b58cebe', 'TP hours', true)
on conflict do nothing;

insert into support_desks (organization_id, key, name, reference_prefix)
values ('88c98875-7f24-4534-a329-f7930b58cebe', 'tp-support', 'Turner Price Support', 'TP')
on conflict do nothing;

insert into support_agents (desk_id, owning_organization_id, profile_id, agent_role)
select d.id, '88c98875-7f24-4534-a329-f7930b58cebe', 'cccccccc-0000-4000-8000-000000000004', 'agent'
from support_desks d where d.key = 'tp-support'
on conflict do nothing;

insert into support_tickets (desk_id, subject, requester_profile_id, requester_organization_id, channel)
select d.id, 'Safeguarding certificate missing', 'dddddddd-0000-4000-8000-000000000005',
       'aaaaaaaa-0000-4000-8000-000000000001', 'portal'
from support_desks d where d.key = 'tp-support';

insert into support_ticket_messages (ticket_id, message_type, direction, body_plain, author_profile_id)
select t.id, 'private_note', 'internal',
       'Customer is threatening to leave. Renewal at risk.', 'cccccccc-0000-4000-8000-000000000004'
from support_tickets t join support_desks d on d.id = t.desk_id where d.key = 'tp-support';

do $$
declare
    r        record;
    v_tick   integer;
    v_msg    integer;
    v_expect integer;
begin
    for r in
        select * from (values
            ('platform owner',     '00000000-0000-4000-8000-000000000001', 0),
            ('platform agent',     '00000000-0000-4000-8000-000000000003', 0),
            ('platform sales',     '00000000-0000-4000-8000-000000000006', 0),
            ('TP admin',           '00000000-0000-4000-8000-000000000002', 1),
            ('TP agent',           '00000000-0000-4000-8000-000000000004', 1),
            ('All Saints learner', '00000000-0000-4000-8000-000000000005', 1)
        ) as x(label, uid, expected)
    loop
        execute 'set local role authenticated';
        execute format('set local request.jwt.claim.sub = %L', r.uid);
        execute 'select count(*) from support_tickets t join support_desks d on d.id = t.desk_id
                 where d.key = ''tp-support''' into v_tick;
        execute 'select count(*) from support_ticket_messages m
                 join support_tickets t on t.id = m.ticket_id
                 join support_desks d on d.id = t.desk_id where d.key = ''tp-support''' into v_msg;
        reset role;

        v_expect := r.expected;
        if v_tick <> v_expect then
            raise exception 'FAIL isolation: % saw % TP ticket(s), expected %', r.label, v_tick, v_expect;
        end if;

        -- The learner is the requester: they see their ticket but must NOT see
        -- the agent's private note.
        if r.label = 'All Saints learner' and v_msg <> 0 then
            raise exception 'FAIL isolation: requester saw % private message(s)', v_msg;
        end if;
        if r.label in ('platform owner', 'platform agent', 'platform sales') and v_msg <> 0 then
            raise exception 'FAIL isolation: % saw % TP message(s)', r.label, v_msg;
        end if;
    end loop;

    raise notice 'cross-tenant isolation ...... PASS';
end $$;

-- ============================= break-glass ===================================
do $$
declare v_desk uuid; v_n integer; v_g uuid;
begin
    select id into v_desk from support_desks where key = 'tp-support';

    set local role authenticated;
    set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
    select count(*) into v_n from support_tickets where desk_id = v_desk;
    reset role;
    if v_n <> 0 then raise exception 'FAIL D1: owner saw % TP tickets with no grant', v_n; end if;

    insert into support_access_grants (granted_to_profile_id, desk_id, reason, expires_at,
                                       granted_by, tenant_notified_at)
    values ('06313023-2de7-455f-8b05-1a4bf88a03eb', v_desk,
            'Tenant asked us to investigate a certificate generation fault on ticket TP-1.',
            now() + interval '60 minutes', '06313023-2de7-455f-8b05-1a4bf88a03eb', now())
    returning id into v_g;

    set local role authenticated;
    set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
    select count(*) into v_n from support_tickets where desk_id = v_desk;
    reset role;
    if v_n <> 1 then raise exception 'FAIL: break-glass did not grant access'; end if;

    update support_access_grants set revoked_at = now() where id = v_g;
    set local role authenticated;
    set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
    select count(*) into v_n from support_tickets where desk_id = v_desk;
    reset role;
    if v_n <> 0 then raise exception 'FAIL: revoked grant still permits access'; end if;

    insert into support_access_grants (granted_to_profile_id, desk_id, reason, granted_at, expires_at)
    values ('06313023-2de7-455f-8b05-1a4bf88a03eb', v_desk,
            'Historic grant that has already expired and must not still work.',
            now() - interval '3 hours', now() - interval '2 hours');
    set local role authenticated;
    set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
    select count(*) into v_n from support_tickets where desk_id = v_desk;
    reset role;
    if v_n <> 0 then raise exception 'FAIL: expired grant still permits access'; end if;

    set local role authenticated;
    set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000002';
    select count(*) into v_n from support_access_grants where desk_id = v_desk;
    reset role;
    if v_n < 2 then raise exception 'FAIL: tenant admin cannot see grants over their own desk'; end if;

    raise notice 'break-glass (D1) ............ PASS';
end $$;

-- ===================== configuration is not break-glass ======================
do $$
declare v_desk uuid; v_ok boolean;
begin
    select id into v_desk from support_desks where key = 'tp-support';

    insert into support_access_grants (granted_to_profile_id, desk_id, reason, expires_at)
    values ('06313023-2de7-455f-8b05-1a4bf88a03eb', v_desk,
            'Second live grant used to prove configuration remains off limits.',
            now() + interval '30 minutes');

    set local role authenticated;
    set local request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
    select support_desk_admin(v_desk) into v_ok;
    reset role;

    if v_ok then
        raise exception 'FAIL: break-glass granted desk ADMIN rights — reading in an emergency is not reconfiguring';
    end if;

    raise notice 'admin separation ............ PASS';
end $$;

do $$ begin raise notice '--- ALL MIGRATION ASSERTS PASSED ---'; end $$;
