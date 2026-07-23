-- ===========================================================================
-- BespokeLMS — Schema migration 008 (Work Management & Kanban engine)
-- Target: Supabase / Postgres.  Depends on 001–007.
--
-- The generic, tenant- and role-scoped task/pipeline engine that the Course
-- Tracker, the client-ideas backlog, and (later) the Marketing pipeline all
-- sit on: boards → stages (Kanban columns) → work_items (cards) with a
-- POLYMORPHIC subject (a card can BE a course/idea/deal or stand alone),
-- priorities, stage-entry automation hooks, board membership, sprints, and an
-- immutable per-item log. Configurable throughout; colours are design tokens.
--
-- Relationship to migration 005: 005 remains the fine-grained, per-course-
-- VERSION editorial approval (draft→in review→approved→published). THIS engine
-- is the higher-level, cross-application production/idea/deal pipeline at the
-- work-item level. They compose (a course card here can reference a version
-- whose editorial state lives in 005). Folding 005 fully into this engine is a
-- later option; kept separate now because 005 is already validated and serves a
-- distinct per-version need.
--
-- Additive + declarative. Seeds a platform Course Production board (14 stages +
-- priorities) and backfills a card per existing course. Validated on Postgres 16.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type work_application        as enum ('course_production','client_ideas','marketing','generic');
create type board_member_role       as enum ('viewer','contributor','manager');
create type work_item_source        as enum ('manual','automation','scheduled','restore');
create type stage_automation_action as enum ('notify_assignee','notify_list','set_assignee','stamp_upload','stamp_review','branch_to','set_priority');

-- ============================== BOARDS =====================================
create table boards (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform template
  application     work_application not null,
  name            text not null,
  is_template     boolean not null default false,
  template_id     uuid references boards(id) on delete set null,        -- origin template
  retention_days  int not null default 180,                             -- archive purge window
  created_by      uuid references profiles(id),
  created_at      timestamptz not null default now()
);
create index on boards(organization_id);
create index on boards(application);

create table board_stages (
  id               uuid primary key default gen_random_uuid(),
  board_id         uuid not null references boards(id) on delete cascade,
  key              text not null,
  label            text not null,
  sort             int  not null default 0,
  colour_bg_token  text,                       -- design-token KEY (never a hex)
  colour_text_token text,
  is_initial       boolean not null default false,
  is_terminal      boolean not null default false,
  is_live          boolean not null default false,   -- a "course is live" column
  default_assignee uuid references profiles(id),
  wip_limit        int,
  created_at       timestamptz not null default now(),
  unique (board_id, key)
);
create index on board_stages(board_id);

create table priorities (
  id               uuid primary key default gen_random_uuid(),
  board_id         uuid not null references boards(id) on delete cascade,
  label            text not null,
  sort             int  not null default 0,          -- Highest=low number → top
  colour_bg_token  text,
  colour_text_token text,
  unique (board_id, label)
);
create index on priorities(board_id);

-- ============================ WORK ITEMS ===================================
create table work_items (
  id             uuid primary key default gen_random_uuid(),
  board_id       uuid not null references boards(id) on delete cascade,
  stage_id       uuid not null references board_stages(id),
  priority_id    uuid references priorities(id),
  assignee_id    uuid references profiles(id),
  title          text not null,
  flag           text,
  notes          text,
  target_go_live date,
  upload_date    date,
  review_date    date,
  source_link    text,                               -- e.g. SharePoint folder
  output_link    text,                               -- e.g. live course URL
  archived       boolean not null default false,
  archived_at    timestamptz,
  created_by     uuid references profiles(id),
  last_updated_at timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
create index on work_items(board_id);
create index on work_items(stage_id);
create index on work_items(assignee_id);
create index on work_items(archived);

-- Polymorphic subject: what this card IS about (or nothing).
create table work_item_subjects (
  work_item_id uuid primary key references work_items(id) on delete cascade,
  subject_type text not null,                         -- 'course' | 'idea' | 'deal' | 'none'
  subject_id   uuid
);
create index on work_item_subjects(subject_type, subject_id);

-- Immutable audit snapshot per change.
create table work_item_log (
  id             uuid primary key default gen_random_uuid(),
  work_item_id   uuid not null references work_items(id) on delete cascade,
  actor_id       uuid references profiles(id),
  changed_fields jsonb not null default '{}'::jsonb,  -- {field: {from, to}}
  source         work_item_source not null default 'manual',
  at             timestamptz not null default now()
);
create index on work_item_log(work_item_id);

-- ===================== MEMBERSHIP / AUTOMATION / SPRINTS ==================
create table board_members (
  board_id   uuid not null references boards(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  board_role board_member_role not null default 'contributor',
  primary key (board_id, profile_id)
);

create table stage_automation (
  id       uuid primary key default gen_random_uuid(),
  stage_id uuid not null references board_stages(id) on delete cascade,
  action   stage_automation_action not null,
  params   jsonb not null default '{}'::jsonb,       -- e.g. {"branch_to":"backlog"} / {"days":365}
  sort     int not null default 0
);
create index on stage_automation(stage_id);

create table sprints (
  id         uuid primary key default gen_random_uuid(),
  board_id   uuid not null references boards(id) on delete cascade,
  name       text not null,
  starts_on  date,
  ends_on    date,
  goal       text,
  status     text not null default 'planned',        -- planned|active|closed
  created_at timestamptz not null default now()
);
create index on sprints(board_id);

create table sprint_items (
  sprint_id    uuid not null references sprints(id) on delete cascade,
  work_item_id uuid not null references work_items(id) on delete cascade,
  committed_at timestamptz not null default now(),
  primary key (sprint_id, work_item_id)
);

-- ===================== RBAC HELPERS (board-scoped) ========================
-- Who may SEE a board: templates are visible to all; otherwise the board's org
-- subtree (or the platform owner). Who may MANAGE: platform owner for platform
-- boards, org-subtree admins for tenant boards. SECURITY DEFINER → no recursion.
create or replace function can_access_board(bid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from boards b
    where b.id = bid
      and ( b.is_template
            or auth_role() = 'bespokelms_owner'
            or (b.organization_id is not null
                and b.organization_id in (select org_and_descendants(auth_org_id()))) )
  );
$$;

create or replace function can_manage_board(bid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from boards b
    where b.id = bid
      and ( (b.organization_id is null and auth_role() = 'bespokelms_owner')
            or (b.organization_id is not null
                and is_admin()
                and b.organization_id in (select org_and_descendants(auth_org_id()))) )
  );
$$;

create or replace function board_of_stage(sid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select board_id from board_stages where id = sid;
$$;

create or replace function board_of_item(wid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select board_id from work_items where id = wid;
$$;

create or replace function board_of_sprint(spid uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select board_id from sprints where id = spid;
$$;

-- ===================== SEED: Course Production board ======================
-- A live, platform-owned board (not a template) so the tracker has real data.
insert into boards (organization_id, application, name, is_template)
select id, 'course_production', 'Course Production', false
from organizations where type = 'platform' limit 1;

insert into board_stages (board_id, key, label, sort, is_initial, is_terminal, is_live)
select b.id, s.key, s.label, s.sort, s.is_initial, s.is_terminal, s.is_live
from boards b,
(values
  ('idea_suggested',       'Idea / Suggested',                 10, true,  false, false),
  ('backlog',              'Backlog',                          20, false, false, false),
  ('review_due_soon',      'Live - Review Due Soon',           30, false, false, true ),
  ('in_planning',          'In planning',                      40, false, false, false),
  ('writing',              'Writing',                          50, false, false, false),
  ('ready_upload',         'Ready for upload',                 60, false, false, false),
  ('uploading',            'Uploading',                        70, false, false, false),
  ('uploaded_review',      'Uploaded - Ready for review',      80, false, false, false),
  ('approved_vo',          'Approved - Ready for VO & publish',90, false, false, false),
  ('vo_production',        'Voiceover in production',         100, false, false, false),
  ('published_vo_approval','Published - Ready for VO approval',110,false, false, false),
  ('approved_live',        'Approved - Live',                 120, false, false, true ),
  ('not_approved',         'Not Approved',                    130, false, true,  false),
  ('review_required',      'Review Required - See Notes',     140, false, false, false)
) as s(key, label, sort, is_initial, is_terminal, is_live)
where b.application = 'course_production' and b.is_template = false;

insert into priorities (board_id, label, sort)
select b.id, p.label, p.sort
from boards b,
(values ('Highest',10),('High',20),('Medium',30),('Low',40),('Lowest',50)) as p(label, sort)
where b.application = 'course_production' and b.is_template = false;

-- Backfill a card per existing course, mapped by catalogue status, with its
-- polymorphic subject pointing at the course. DO block → reliable item↔course map.
do $$
declare bid uuid; pid uuid; wid uuid; sid uuid; c record;
begin
  select id into bid from boards where application = 'course_production' and is_template = false limit 1;
  select id into pid from priorities where board_id = bid and label = 'Medium' limit 1;
  for c in select id, title, catalog_status from courses loop
    select id into sid from board_stages
      where board_id = bid
        and key = case c.catalog_status
                    when 'published' then 'approved_live'
                    when 'retired'   then 'not_approved'
                    else 'backlog'
                  end;
    insert into work_items (board_id, stage_id, priority_id, title)
    values (bid, sid, pid, c.title) returning id into wid;
    insert into work_item_subjects (work_item_id, subject_type, subject_id)
    values (wid, 'course', c.id);
  end loop;
end $$;

-- A Client Ideas board template (stages only) so idea intake has a home.
insert into boards (organization_id, application, name, is_template)
values (null, 'client_ideas', 'Client Ideas', true);
insert into board_stages (board_id, key, label, sort, is_initial, is_terminal)
select b.id, s.key, s.label, s.sort, s.is_initial, s.is_terminal
from boards b,
(values
  ('idea_suggested','Idea / Suggested',10,true,false),
  ('backlog','Backlog',20,false,false),
  ('rejected','Rejected',30,false,true)
) as s(key,label,sort,is_initial,is_terminal)
where b.application = 'client_ideas' and b.is_template = true;

-- ========================= ROW-LEVEL SECURITY =============================
alter table boards             enable row level security;
alter table board_stages       enable row level security;
alter table priorities         enable row level security;
alter table work_items         enable row level security;
alter table work_item_subjects enable row level security;
alter table work_item_log      enable row level security;
alter table board_members      enable row level security;
alter table stage_automation   enable row level security;
alter table sprints            enable row level security;
alter table sprint_items       enable row level security;

create policy boards_read   on boards for select using ( can_access_board(id) );
create policy boards_manage on boards for all using ( can_manage_board(id) ) with check ( can_manage_board(id) );

create policy stages_read   on board_stages for select using ( can_access_board(board_id) );
create policy stages_manage on board_stages for all using ( can_manage_board(board_id) ) with check ( can_manage_board(board_id) );

create policy priorities_read   on priorities for select using ( can_access_board(board_id) );
create policy priorities_manage on priorities for all using ( can_manage_board(board_id) ) with check ( can_manage_board(board_id) );

create policy items_read   on work_items for select using ( can_access_board(board_id) );
create policy items_manage on work_items for all using ( can_manage_board(board_id) ) with check ( can_manage_board(board_id) );

create policy subjects_read   on work_item_subjects for select using ( can_access_board(board_of_item(work_item_id)) );
create policy subjects_manage on work_item_subjects for all using ( can_manage_board(board_of_item(work_item_id)) ) with check ( can_manage_board(board_of_item(work_item_id)) );

create policy itemlog_read   on work_item_log for select using ( can_access_board(board_of_item(work_item_id)) );
create policy itemlog_manage on work_item_log for all using ( can_manage_board(board_of_item(work_item_id)) ) with check ( can_manage_board(board_of_item(work_item_id)) );

create policy members_read   on board_members for select using ( can_access_board(board_id) );
create policy members_manage on board_members for all using ( can_manage_board(board_id) ) with check ( can_manage_board(board_id) );

create policy automation_read   on stage_automation for select using ( can_access_board(board_of_stage(stage_id)) );
create policy automation_manage on stage_automation for all using ( can_manage_board(board_of_stage(stage_id)) ) with check ( can_manage_board(board_of_stage(stage_id)) );

create policy sprints_read   on sprints for select using ( can_access_board(board_id) );
create policy sprints_manage on sprints for all using ( can_manage_board(board_id) ) with check ( can_manage_board(board_id) );

create policy sprint_items_read   on sprint_items for select using ( can_access_board(board_of_sprint(sprint_id)) );
create policy sprint_items_manage on sprint_items for all using ( can_manage_board(board_of_sprint(sprint_id)) ) with check ( can_manage_board(board_of_sprint(sprint_id)) );

-- ============================ GRANTS =======================================
grant select on
  boards, board_stages, priorities, work_items, work_item_subjects,
  work_item_log, board_members, stage_automation, sprints, sprint_items
  to anon, authenticated;
grant insert, update, delete on
  boards, board_stages, priorities, work_items, work_item_subjects,
  work_item_log, board_members, stage_automation, sprints, sprint_items
  to authenticated;
grant execute on function
  can_access_board(uuid), can_manage_board(uuid),
  board_of_stage(uuid), board_of_item(uuid), board_of_sprint(uuid)
  to anon, authenticated;

-- NOTE: stage-entry automation (stage_automation rows) is executed by a Laravel
-- service on a StageEntered event — stamp dates, (re)assign, set priority,
-- branch — writing a work_item_log row with source='automation' and dispatching
-- notifications via the separate notifications module. The review-due cron and
-- board_members-based finer permissions layer on next.
