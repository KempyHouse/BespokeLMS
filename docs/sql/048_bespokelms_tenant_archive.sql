-- =============================================================================
-- BespokeLMS — Supabase migration 048 (applied 2026-07-25)
-- Tenant archive workflow — stage 1 of the two-stage deletion model.
-- Reference copy of migration applied to project pqmdtqsscyltykgcwwus:
--   bespokelms_tenant_archive_048
-- =============================================================================

-- Archiving a tenant revokes access and hides it from listings while
-- preserving every row for recovery; permanent purge is a later, separate
-- stage gated on purge_after (archive sets it to +30 days app-side).
-- App layer: ReadsOrganizations::all() is active-only; the platform console
-- reads allIncludingArchived(); EnsureOrganizationActive middleware signs
-- archived-workspace users out (cached archived-id set, ~60s, fail-open).

alter table public.organizations
  add column archived_at timestamptz,
  add column archive_reason text,
  add column archive_note text,
  add column archived_by uuid references public.profiles(id) on delete set null,
  add column purge_after timestamptz,
  add column restored_at timestamptz,
  add column restored_by uuid references public.profiles(id) on delete set null;

comment on column public.organizations.archived_at is
  'Stage-1 soft deletion: set = tenant disabled + hidden, data preserved.';
comment on column public.organizations.archive_reason is
  'Controlled list app-side (mock/duplicate/test/error/other).';
comment on column public.organizations.purge_after is
  'Earliest date the stage-2 permanent purge may run (retention window).';

-- The purge job scans archived tenants only; keep that scan cheap.
create index organizations_archived_purge_idx
  on public.organizations (purge_after)
  where archived_at is not null;

-- The platform organisation is the root of the estate and must never be
-- archived, whatever the app layer does.
create or replace function public.org_archive_guard()
returns trigger
language plpgsql
as $$
begin
  if new.archived_at is not null and new.type = 'platform' then
    raise exception 'The platform organisation cannot be archived.';
  end if;
  return new;
end;
$$;

create trigger org_archive_guard
  before update of archived_at on public.organizations
  for each row
  execute function public.org_archive_guard();

-- Proven with rolled-back asserts on 2026-07-25:
--   1. archiving a client stamps archived_at/reason/by/purge_after  ✓
--   2. restore clears the archive state and stamps restored_at      ✓
--   3. the platform organisation refuses to archive (trigger)       ✓
