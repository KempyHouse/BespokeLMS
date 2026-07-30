-- 284: contract wording changed once, not twelve times.
--
-- WHY. esign_templates hold a whole agreement as a single block of HTML. That
-- works for one document and fails across a pipeline: changing a liability cap
-- or a retention period means editing every template by hand and hoping none
-- was missed. There are eleven foodservice prospects in the CRM behind Turner
-- Price, all of whom get substantially the same agreement.
--
-- Clauses are versioned and never edited in place, so a signed agreement can
-- always be read back as it stood on the day it was signed. That is also what
-- makes "which live contracts still carry the superseded liability cap" a
-- query rather than an afternoon.
--
-- owning_organization_id is NULLABLE on purpose, matching esign_templates:
-- null means the platform catalogue, which tenants may use but never edit.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170433).

create type public.contract_clause_category as enum (
    'definitions', 'scope_of_service', 'service_levels', 'data_protection',
    'security', 'liability', 'indemnity', 'payment', 'term_termination',
    'intellectual_property', 'confidentiality', 'exclusivity',
    'acceptable_use', 'warranties', 'general'
);

create type public.contract_clause_status as enum ('draft', 'approved', 'retired');

create table public.contract_clauses (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid references public.organizations (id) on delete cascade,
    key text not null,
    title text not null,
    category public.contract_clause_category not null,
    status public.contract_clause_status not null default 'draft',
    is_negotiable boolean not null default false,
    guidance text,
    owner_profile_id uuid references public.profiles (id),
    current_version_no integer not null default 0,
    created_by uuid references public.profiles (id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
);

comment on table public.contract_clauses is
  'A reusable contract clause. Tenant-scoped, or platform catalogue when owning_organization_id is null.';
comment on column public.contract_clauses.is_negotiable is
  'Whether a salesperson may vary this clause for a deal without escalating. Liability and data protection clauses should not be.';

create unique index contract_clauses_key_org_idx on public.contract_clauses (owning_organization_id, key)
    where owning_organization_id is not null;
create unique index contract_clauses_key_platform_idx on public.contract_clauses (key)
    where owning_organization_id is null;
create index contract_clauses_category_idx on public.contract_clauses (owning_organization_id, category, status);

create trigger contract_clauses_touch
    before update on public.contract_clauses
    for each row execute function public.sales_touch_updated_at();

create table public.contract_clause_versions (
    id uuid primary key default gen_random_uuid(),
    clause_id uuid not null references public.contract_clauses (id) on delete cascade,
    version_no integer not null,
    body_html text not null,
    sha256 text,
    change_note text,
    effective_from date,
    approved_by uuid references public.profiles (id),
    approved_at timestamptz,
    created_by uuid references public.profiles (id),
    created_at timestamptz not null default now(),
    constraint contract_clause_versions_unique unique (clause_id, version_no)
);

comment on table public.contract_clause_versions is
  'Immutable wording. A clause is never edited in place -- a new version supersedes it, so a signed agreement can always be read back as it stood.';

create index contract_clause_versions_clause_idx on public.contract_clause_versions (clause_id, version_no desc);

-- Templates composed FROM clauses rather than pasted as one block. Existing
-- whole-HTML templates keep working untouched: a template with no rows here
-- behaves exactly as it does today. Migration path, not a breaking change.
create table public.esign_template_clauses (
    id uuid primary key default gen_random_uuid(),
    template_id uuid not null references public.esign_templates (id) on delete cascade,
    clause_id uuid not null references public.contract_clauses (id) on delete restrict,
    clause_version_id uuid references public.contract_clause_versions (id) on delete restrict,
    position integer not null default 0,
    is_required boolean not null default true,
    created_at timestamptz not null default now(),
    constraint esign_template_clauses_unique unique (template_id, clause_id)
);

comment on table public.esign_template_clauses is
  'Ordered composition of a template from clauses. A null clause_version_id means always take the current approved version.';

create index esign_template_clauses_template_idx on public.esign_template_clauses (template_id, position);

-- What a specific document actually used, PINNED. This is the audit trail that
-- did not exist for the Turner Price exclusivity clause: a negotiated
-- departure from standard wording, with who approved it and why.
create table public.esign_document_clauses (
    id uuid primary key default gen_random_uuid(),
    document_id uuid not null references public.esign_documents (id) on delete cascade,
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    clause_id uuid references public.contract_clauses (id) on delete set null,
    clause_version_id uuid references public.contract_clause_versions (id) on delete set null,
    position integer not null default 0,
    is_varied boolean not null default false,
    varied_body_html text,
    variation_reason text,
    approved_by uuid references public.profiles (id),
    approved_at timestamptz,
    created_at timestamptz not null default now(),
    constraint esign_document_clauses_variation_explained check (
        not is_varied or (variation_reason is not null and length(btrim(variation_reason)) > 0)
    )
);

comment on table public.esign_document_clauses is
  'The clauses as they stood on a specific agreement, pinned to a version. A variation cannot be recorded without a reason.';

create index esign_document_clauses_document_idx on public.esign_document_clauses (document_id, position);
create index esign_document_clauses_clause_idx on public.esign_document_clauses (clause_id, clause_version_id);

-- Reverse lookup: which agreements carry a given clause version, and are they
-- still live. This is the question a wording change has to answer first.
create view public.v_contract_clause_usage as
select
    c.id as clause_id, c.key as clause_key, c.title as clause_title, c.category,
    cv.id as clause_version_id, cv.version_no,
    dc.document_id, d.title as document_title, d.status as document_status,
    d.owning_organization_id, dc.is_varied, dc.variation_reason
from public.contract_clauses c
join public.contract_clause_versions cv on cv.clause_id = c.id
join public.esign_document_clauses dc on dc.clause_version_id = cv.id
join public.esign_documents d on d.id = dc.document_id;

comment on view public.v_contract_clause_usage is
  'Which documents use which clause version. Answers: which signed agreements still carry the superseded liability cap.';

-- Keep current_version_no honest without the application having to remember.
create or replace function public.contract_clause_version_sync()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
    update contract_clauses
       set current_version_no = greatest(current_version_no, new.version_no),
           updated_at = now()
     where id = new.clause_id;
    return new;
end;
$$;

create trigger contract_clause_versions_sync
    after insert on public.contract_clause_versions
    for each row execute function public.contract_clause_version_sync();

alter table public.contract_clauses enable row level security;
alter table public.contract_clause_versions enable row level security;
alter table public.esign_template_clauses enable row level security;
alter table public.esign_document_clauses enable row level security;

-- Tenant clauses are the tenant's. Platform-catalogue clauses are readable by
-- anyone with the esign module and writable only by the platform owner -- the
-- same shape as the esign_templates policy.
create policy contract_clauses_org on public.contract_clauses
    for all using (
        (owning_organization_id is not null and public.sales_org_access(owning_organization_id))
        or (owning_organization_id is null and status = 'approved' and exists (
              select 1 from public.profiles p
              where p.auth_user_id = auth.uid() and public.module_enabled(p.organization_id, 'esign')))
    )
    with check (
        (owning_organization_id is not null and public.sales_org_access(owning_organization_id))
        or (owning_organization_id is null and exists (
              select 1 from public.profiles p
              where p.auth_user_id = auth.uid() and p.role = 'bespokelms_owner'))
    );

create policy contract_clause_versions_org on public.contract_clause_versions
    for all using (exists (
        select 1 from public.contract_clauses c
        where c.id = clause_id
          and ((c.owning_organization_id is not null and public.sales_org_access(c.owning_organization_id))
               or (c.owning_organization_id is null and exists (
                     select 1 from public.profiles p
                     where p.auth_user_id = auth.uid() and public.module_enabled(p.organization_id, 'esign'))))
    ))
    with check (exists (
        select 1 from public.contract_clauses c
        where c.id = clause_id
          and ((c.owning_organization_id is not null and public.sales_org_access(c.owning_organization_id))
               or (c.owning_organization_id is null and exists (
                     select 1 from public.profiles p
                     where p.auth_user_id = auth.uid() and p.role = 'bespokelms_owner')))
    ));

create policy esign_template_clauses_org on public.esign_template_clauses
    for all using (exists (
        select 1 from public.esign_templates t
        where t.id = template_id
          and ((t.owning_organization_id is not null and public.sales_org_access(t.owning_organization_id))
               or (t.owning_organization_id is null and exists (
                     select 1 from public.profiles p
                     where p.auth_user_id = auth.uid() and public.module_enabled(p.organization_id, 'esign'))))
    ))
    with check (exists (
        select 1 from public.esign_templates t
        where t.id = template_id
          and ((t.owning_organization_id is not null and public.sales_org_access(t.owning_organization_id))
               or (t.owning_organization_id is null and exists (
                     select 1 from public.profiles p
                     where p.auth_user_id = auth.uid() and p.role = 'bespokelms_owner')))
    ));

create policy esign_document_clauses_org on public.esign_document_clauses
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));
