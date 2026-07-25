-- 051_bespokelms_invitations.sql
--
-- Membership invitations.
--
-- Until now profiles were created directly, which left the account_invited
-- email with nothing to fire it and no way to expire, re-send or revoke an
-- invitation. The token is stored hashed and is single use; the plaintext
-- exists only in the message that carried it.
--
-- Seven days matches the widely-copied GitHub default and is short enough that
-- an invitation left in a leaked mailbox stops being useful quickly.
--
-- Research: docs/BespokeLMS-System-Emails-Research.md section 6.1.

create type invitation_status as enum ('pending', 'accepted', 'revoked', 'expired');

create table invitations (
  id                  uuid primary key default gen_random_uuid(),
  organization_id     uuid not null references organizations (id) on delete cascade,
  email               text not null,
  role                app_role not null,
  team_id             uuid references teams (id) on delete set null,
  job_title           text,
  first_name          text,
  last_name           text,
  invited_by          uuid references profiles (id) on delete set null,
  token_hash          text not null,
  status              invitation_status not null default 'pending',
  expires_at          timestamptz not null default (now() + interval '7 days'),
  accepted_at         timestamptz,
  accepted_profile_id uuid references profiles (id) on delete set null,
  revoked_at          timestamptz,
  revoked_by          uuid references profiles (id) on delete set null,
  last_reminded_at    timestamptz,
  reminder_count      integer not null default 0,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),

  constraint invitations_email_shape check (position('@' in email) > 1),
  constraint invitations_expiry_future check (expires_at > created_at),
  -- One reminder is conversion; four is harassment, and it is the recipient
  -- marking us as spam that damages every other tenant's deliverability.
  constraint invitations_reminder_cap check (reminder_count between 0 and 3),
  constraint invitations_accepted_has_profile
    check (status <> 'accepted' or (accepted_at is not null and accepted_profile_id is not null)),
  constraint invitations_revoked_has_time
    check (status <> 'revoked' or revoked_at is not null),
  constraint invitations_no_owner_invites check (role <> 'bespokelms_owner')
);

comment on table invitations is
  'Pending membership invitations. The token is stored hashed and is single use; an invitation expires seven days after issue.';
comment on column invitations.token_hash is
  'SHA-256 of the invitation token. The plaintext token exists only in the email that carried it.';
comment on column invitations.role is
  'The role the invitee will hold on acceptance. Named in the invitation email, because specificity is the anti-phishing control.';
comment on constraint invitations_no_owner_invites on invitations is
  'The platform-owner tier is never granted by invitation.';

create unique index invitations_token_uniq on invitations (token_hash);

-- A second live invitation to the same address in the same tenant would give
-- the recipient two valid tokens and the admin no way to tell which was used.
create unique index invitations_one_live_per_email
  on invitations (organization_id, lower(email))
  where status = 'pending';

create index invitations_org_idx on invitations (organization_id, status);
create index invitations_expiry_sweep_idx on invitations (expires_at) where status = 'pending';

create or replace function invitations_touch()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;

create trigger invitations_touch_updated_at
  before update on invitations
  for each row execute function invitations_touch();

revoke execute on function invitations_touch() from public, anon, authenticated;

alter table invitations enable row level security;

-- Acceptance runs server-side with the service role, so there is deliberately
-- no anon policy: an unauthenticated caller can never read an invitation row,
-- only present a token to the application.
create policy invitations_admin on invitations
  for all to authenticated
  using (
    is_platform_owner()
    or (is_admin() and organization_id in (select org_and_descendants(auth_org_id())))
  )
  with check (
    is_platform_owner()
    or (is_admin() and organization_id in (select org_and_descendants(auth_org_id())))
  );
