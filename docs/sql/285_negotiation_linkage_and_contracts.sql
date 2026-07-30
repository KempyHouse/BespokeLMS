-- 285: the negotiation, and what was actually agreed.
--
-- TWO HOLES CLOSED HERE.
--
-- First, mail_threads linked to a contact, an account and a support ticket but
-- NOT to a deal, so the back-and-forth that settles a price landed in the
-- inbox and never attached to the opportunity it was about.
--
-- Second, once an agreement was signed the platform kept a filed PDF and a Won
-- deal, and knew nothing else. The Turner Price agreement commits both parties
-- to a three-year term, a 3,000 Active User minimum, quarterly measurement on
-- peak usage and a CPI+3 per cent uplift ceiling. None of that was data, so
-- nothing could say when to invoice the overage or when the renewal notice
-- window opened.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170515).

alter table public.mail_threads
    add column deal_id uuid references public.crm_deals (id) on delete set null;

comment on column public.mail_threads.deal_id is
  'The opportunity this conversation belongs to. Lets a negotiation thread be pinned to the deal it is about.';

create index mail_threads_deal_idx on public.mail_threads (deal_id) where deal_id is not null;

-- The offer history. E-sign could already supersede version 1 with version 2
-- but could not say why, or at what price.
create type public.deal_offer_kind as enum ('offered', 'countered', 'agreed', 'withdrawn');
create type public.deal_offer_party as enum ('us', 'them');

create table public.crm_deal_offers (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    deal_id uuid not null references public.crm_deals (id) on delete cascade,
    document_id uuid references public.esign_documents (id) on delete set null,
    document_version_no integer,
    kind public.deal_offer_kind not null,
    party public.deal_offer_party not null,
    total_minor bigint,
    currency character(3) not null default 'GBP',
    summary text not null,
    is_final boolean not null default false,
    occurred_at timestamptz not null default now(),
    created_by uuid references public.profiles (id),
    created_at timestamptz not null default now()
);

comment on table public.crm_deal_offers is
  'What was offered, what came back, and what was agreed. The negotiation record that sat only in an inbox before.';

create index crm_deal_offers_deal_idx on public.crm_deal_offers (deal_id, occurred_at);
create unique index crm_deal_offers_one_final_idx on public.crm_deal_offers (deal_id) where is_final;

create type public.contract_status as enum ('pending', 'active', 'expired', 'terminated', 'superseded');
create type public.contract_renewal_type as enum ('automatic', 'manual', 'none');

create table public.contracts (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    account_id uuid references public.crm_accounts (id) on delete set null,
    deal_id uuid references public.crm_deals (id) on delete set null,
    document_id uuid references public.esign_documents (id) on delete set null,
    reference text,
    title text not null,
    status public.contract_status not null default 'pending',
    counterparty_name text,
    currency character(3) not null default 'GBP',
    term_start date,
    term_end date,
    initial_term_months integer check (initial_term_months > 0),
    renewal_type public.contract_renewal_type not null default 'automatic',
    renewal_term_months integer check (renewal_term_months > 0),
    renewal_notice_days integer check (renewal_notice_days >= 0),
    next_renewal_on date,
    notice_deadline_on date,
    uplift_index text,
    uplift_cap_percent numeric(5,2) check (uplift_cap_percent >= 0),
    exclusivity_note text,
    signed_at timestamptz,
    notes text,
    created_by uuid references public.profiles (id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint contracts_term_order check (term_end is null or term_start is null or term_end >= term_start),
    constraint contracts_reference_unique unique (owning_organization_id, reference)
);

comment on table public.contracts is
  'A signed agreement with its commercial terms held as data rather than as prose, so renewal and measurement can be driven from it.';
comment on column public.contracts.notice_deadline_on is
  'The last day to serve notice and stop automatic renewal. Derived from next_renewal_on less renewal_notice_days.';
comment on column public.contracts.uplift_index is
  'The index a renewal uplift is tied to, for example UK CPI. Read with uplift_cap_percent: CPI plus 3 per cent.';

create index contracts_org_status_idx on public.contracts (owning_organization_id, status);
create index contracts_renewal_idx on public.contracts (next_renewal_on) where status = 'active';
create index contracts_notice_idx on public.contracts (notice_deadline_on) where status = 'active';

create trigger contracts_touch
    before update on public.contracts
    for each row execute function public.sales_touch_updated_at();

-- Keep the notice deadline consistent with the renewal date it derives from,
-- so a reminder can never be scheduled against a stale figure.
create or replace function public.contract_notice_deadline_sync()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
    if new.next_renewal_on is not null and new.renewal_notice_days is not null then
        new.notice_deadline_on := new.next_renewal_on - new.renewal_notice_days;
    end if;
    return new;
end;
$$;

create trigger contracts_notice_deadline
    before insert or update on public.contracts
    for each row execute function public.contract_notice_deadline_sync();

-- What was committed, and how it is measured.
create table public.contract_commitments (
    id uuid primary key default gen_random_uuid(),
    contract_id uuid not null references public.contracts (id) on delete cascade,
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    product_id uuid references public.sales_products (id) on delete set null,
    line_item_id uuid references public.esign_line_items (id) on delete set null,
    description text not null,
    billing_kind public.product_billing_kind not null,
    recurrence public.product_recurrence not null default 'none',
    unit_price_minor bigint not null default 0 check (unit_price_minor >= 0),
    currency character(3) not null default 'GBP',
    committed_minimum_quantity numeric(14,2) check (committed_minimum_quantity >= 0),
    ceiling_quantity numeric(14,2) check (ceiling_quantity >= 0),
    billing_block_size numeric(14,2) check (billing_block_size > 0),
    measurement_basis public.usage_measurement_basis,
    measurement_frequency public.usage_measurement_frequency,
    measured_in_arrears boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint contract_commitments_ceiling_above_minimum check (
        ceiling_quantity is null or committed_minimum_quantity is null
        or ceiling_quantity >= committed_minimum_quantity
    )
);

comment on table public.contract_commitments is
  'A committed term on a contract. Turner Price: GBP 2.00 per Active User, minimum 3,000, ceiling 10,000, peak measured quarterly in arrears, invoiced in blocks of 100.';

create index contract_commitments_contract_idx on public.contract_commitments (contract_id);

create trigger contract_commitments_touch
    before update on public.contract_commitments
    for each row execute function public.sales_touch_updated_at();

-- What was actually measured, against what was committed. Overage is invoiced
-- on evidence rather than on trust.
create table public.contract_usage_measurements (
    id uuid primary key default gen_random_uuid(),
    contract_id uuid not null references public.contracts (id) on delete cascade,
    commitment_id uuid not null references public.contract_commitments (id) on delete cascade,
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    period_start date not null,
    period_end date not null,
    measured_quantity numeric(14,2) not null check (measured_quantity >= 0),
    chargeable_quantity numeric(14,2) not null default 0 check (chargeable_quantity >= 0),
    chargeable_amount_minor bigint not null default 0 check (chargeable_amount_minor >= 0),
    currency character(3) not null default 'GBP',
    method_note text,
    measured_at timestamptz not null default now(),
    invoiced_at timestamptz,
    created_by uuid references public.profiles (id),
    created_at timestamptz not null default now(),
    constraint contract_usage_period_order check (period_end >= period_start),
    constraint contract_usage_period_unique unique (commitment_id, period_start, period_end)
);

comment on table public.contract_usage_measurements is
  'Measured usage for a period against a commitment, with the chargeable overage worked out. The evidence behind an overage invoice.';

create index contract_usage_contract_idx on public.contract_usage_measurements (contract_id, period_start desc);

alter table public.crm_deal_offers enable row level security;
alter table public.contracts enable row level security;
alter table public.contract_commitments enable row level security;
alter table public.contract_usage_measurements enable row level security;

create policy crm_deal_offers_org on public.crm_deal_offers
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));

create policy contracts_org on public.contracts
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));

create policy contract_commitments_org on public.contract_commitments
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));

create policy contract_usage_measurements_org on public.contract_usage_measurements
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));
