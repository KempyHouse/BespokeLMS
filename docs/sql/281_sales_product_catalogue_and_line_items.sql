-- 281: proposals stop being priced from memory.
--
-- WHY. An opportunity carried a single amount (crm_deals.value_minor) and
-- nothing else, and a proposal was free-text HTML, so every figure on it was
-- typed by hand. The executed Turner Price agreement states GBP 2.00 per
-- Active User and an indicative GBP 6,600 at 3,000 Active Users in the same
-- table. 3,000 x 2.00 is 6,000. Both cannot be true, and neither the CRM nor
-- the document could tell anyone which was meant.
--
-- A computed line total cannot contradict its own unit price and quantity.
-- That is the whole point of esign_line_items.line_total_minor being a
-- generated column rather than a number somebody keys in.
--
-- Tenant-scoped from the start. The module is off for tenants for now, but
-- retrofitting tenancy later is the expensive way round.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170311).

create or replace function public.sales_org_access(org uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select (module_enabled(org, 'sales_crm') or module_enabled(org, 'esign'))
     and exists (
       select 1 from profiles p
       where p.auth_user_id = auth.uid()
         and p.organization_id = org
         and (p.role in ('bespokelms_owner','lms_operator_admin','client_admin')
              or exists (select 1 from profile_capabilities pc
                         where pc.profile_id = p.id and pc.capability = 'sales'))
     );
$$;

comment on function public.sales_org_access(uuid) is
  'Row-level access for the commercial layer: products, proposal line items, clauses and contracts. Requires either the sales_crm or the esign module and a sales-standing role.';

create or replace function public.sales_touch_updated_at()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
    new.updated_at := now();
    return new;
end;
$$;

-- 'included' covers the content licence that carries no separate fee but must
-- still appear on the proposal -- priced at zero on purpose, not omitted.
create type public.product_billing_kind as enum ('one_off', 'recurring', 'per_unit_usage', 'included');
create type public.product_recurrence as enum ('none', 'monthly', 'quarterly', 'annual');

-- How a usage line is measured against its commitment. Turner Price is
-- measured on the highest number of Active Users in any single month.
create type public.usage_measurement_basis as enum ('peak', 'average', 'closing');
create type public.usage_measurement_frequency as enum ('monthly', 'quarterly', 'annual');

create table public.sales_products (
    id uuid primary key default gen_random_uuid(),
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    code text not null,
    name text not null,
    description text,
    billing_kind public.product_billing_kind not null default 'one_off',
    recurrence public.product_recurrence not null default 'none',
    unit_label text,
    list_price_minor bigint not null default 0 check (list_price_minor >= 0),
    currency character(3) not null default 'GBP',
    is_active boolean not null default true,
    sort_order integer not null default 0,
    created_by uuid references public.profiles (id),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint sales_products_code_unique unique (owning_organization_id, code),
    constraint sales_products_recurrence_agrees check (
        (billing_kind = 'recurring' and recurrence <> 'none')
        or (billing_kind <> 'recurring' and recurrence = 'none')
    )
);

comment on table public.sales_products is
  'Tenant-scoped catalogue of sellable products. A proposal line is priced from here rather than typed from memory.';
comment on column public.sales_products.unit_label is
  'What one unit is, for per-unit lines. For example: Active User per annum.';

create index sales_products_org_idx on public.sales_products (owning_organization_id, is_active, sort_order);

create trigger sales_products_touch
    before update on public.sales_products
    for each row execute function public.sales_touch_updated_at();

-- Line items hang off the e-sign document, which is what a proposal already
-- is. Product details are snapshotted onto the line so that changing the
-- catalogue later never rewrites the history of what was offered.
create table public.esign_line_items (
    id uuid primary key default gen_random_uuid(),
    document_id uuid not null references public.esign_documents (id) on delete cascade,
    owning_organization_id uuid not null references public.organizations (id) on delete cascade,
    product_id uuid references public.sales_products (id) on delete set null,
    position integer not null default 0,
    description text not null,
    billing_kind public.product_billing_kind not null default 'one_off',
    recurrence public.product_recurrence not null default 'none',
    unit_label text,
    quantity numeric(14,2) not null default 1 check (quantity >= 0),
    unit_price_minor bigint not null default 0 check (unit_price_minor >= 0),
    discount_percent numeric(5,2) not null default 0 check (discount_percent >= 0 and discount_percent <= 100),
    discount_amount_minor bigint not null default 0 check (discount_amount_minor >= 0),
    currency character(3) not null default 'GBP',
    is_optional boolean not null default false,
    committed_minimum_quantity numeric(14,2) check (committed_minimum_quantity >= 0),
    ceiling_quantity numeric(14,2) check (ceiling_quantity >= 0),
    measurement_basis public.usage_measurement_basis,
    measurement_frequency public.usage_measurement_frequency,
    billing_block_size numeric(14,2) check (billing_block_size > 0),
    notes text,
    line_total_minor bigint not null generated always as (
        greatest(0, (round(quantity * unit_price_minor * (1 - discount_percent / 100)) - discount_amount_minor)::bigint)
    ) stored,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint esign_line_items_ceiling_above_minimum check (
        ceiling_quantity is null or committed_minimum_quantity is null
        or ceiling_quantity >= committed_minimum_quantity
    ),
    constraint esign_line_items_usage_fields_only_on_usage check (
        billing_kind = 'per_unit_usage'
        or (committed_minimum_quantity is null and ceiling_quantity is null
            and measurement_basis is null and measurement_frequency is null
            and billing_block_size is null)
    )
);

comment on table public.esign_line_items is
  'Priced lines on a proposal. line_total_minor is computed, so a stated total can never contradict its own unit price and quantity.';
comment on column public.esign_line_items.is_optional is
  'An optional line is quoted but excluded from the committed total -- for example bespoke courses at GBP 1,200 each.';
comment on column public.esign_line_items.billing_block_size is
  'Usage above the committed minimum is invoiced in blocks of this size. Turner Price: blocks of 100 Active Users.';

create index esign_line_items_document_idx on public.esign_line_items (document_id, position);
create index esign_line_items_org_idx on public.esign_line_items (owning_organization_id);

create trigger esign_line_items_touch
    before update on public.esign_line_items
    for each row execute function public.sales_touch_updated_at();

-- A line must belong to the same organisation as the document it prices, and
-- to a product from that same organisation. Cross-tenant leakage through a
-- foreign key is the failure mode worth spending a trigger on.
create or replace function public.esign_line_item_tenant_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
    v_doc_org uuid;
    v_product_org uuid;
begin
    select owning_organization_id into v_doc_org from esign_documents where id = new.document_id;

    if v_doc_org is distinct from new.owning_organization_id then
        raise exception 'A proposal line must belong to the same organisation as its document.';
    end if;

    if new.product_id is not null then
        select owning_organization_id into v_product_org from sales_products where id = new.product_id;

        if v_product_org is distinct from new.owning_organization_id then
            raise exception 'A proposal line cannot be priced from another organisation''s product.';
        end if;
    end if;

    return new;
end;
$$;

create trigger esign_line_items_tenant_guard
    before insert or update on public.esign_line_items
    for each row execute function public.esign_line_item_tenant_guard();

-- Totals, so the application never re-implements the arithmetic.
create view public.v_esign_document_totals as
select
    li.document_id,
    li.owning_organization_id,
    max(li.currency) as currency,
    coalesce(sum(li.line_total_minor) filter (where not li.is_optional and li.billing_kind = 'one_off'), 0) as one_off_total_minor,
    coalesce(sum(li.line_total_minor) filter (where not li.is_optional and li.billing_kind in ('recurring','per_unit_usage')), 0) as recurring_total_minor,
    coalesce(sum(li.line_total_minor) filter (where not li.is_optional), 0) as first_period_total_minor,
    coalesce(sum(li.line_total_minor) filter (where li.is_optional), 0) as optional_total_minor,
    count(*) as line_count
from public.esign_line_items li
group by li.document_id, li.owning_organization_id;

comment on view public.v_esign_document_totals is
  'Computed proposal totals. first_period_total_minor is what is committed for the first period; optional lines are quoted but excluded.';

alter table public.sales_products enable row level security;
alter table public.esign_line_items enable row level security;

create policy sales_products_org on public.sales_products
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));

create policy esign_line_items_org on public.esign_line_items
    for all using (public.sales_org_access(owning_organization_id))
    with check (public.sales_org_access(owning_organization_id));
