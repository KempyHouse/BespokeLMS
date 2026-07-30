-- 289: the real BespokeLMS product catalogue.
--
-- These are genuine sellable products, taken from the executed Turner Price
-- SaaS Agreement v2.01 -- not sample data. Prices are in minor units (pence)
-- throughout, matching crm_deals.value_minor.
--
-- Reads together as the reference case for every billing_kind the catalogue
-- supports: a one-off configuration fee, an annual recurring licence, an
-- included content licence priced at zero on purpose, a per-unit usage line,
-- and an optional one-off.
--
-- The Turner Price contract itself, its commitments, and the
-- email_engagement_settings row for BespokeLMS were inserted as data rather
-- than as a migration, since they are records of one customer rather than
-- schema. See the contracts table for TP-SAAS-2026-001.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29 (migration 20260729170801).

insert into public.sales_products
    (owning_organization_id, code, name, description, billing_kind, recurrence,
     unit_label, list_price_minor, currency, sort_order, created_by)
select
    o.id, v.code, v.name, v.description, v.billing_kind::public.product_billing_kind,
    v.recurrence::public.product_recurrence, v.unit_label, v.price, 'GBP', v.sort_order, p.id
from public.organizations o
cross join (values
    ('CONFIG-ENV',
     'Configuration — client learning environment',
     'One-off configuration and branding of the client''s white-label learning environment.',
     'one_off', 'none', null, 500000, 10),

    ('PLATFORM-LICENCE',
     'Platform licence — white-label training platform',
     'Annual licence for the client-branded BespokeLMS platform.',
     'recurring', 'annual', null, 1000000, 20),

    ('CONTENT-P12',
     'Content licence — Phase 1 and 2 course library',
     'CPD-certified food safety, allergen awareness and hospitality compliance courses. Included with the platform licence at no separate annual fee.',
     'included', 'none', null, 0, 30),

    ('ACTIVE-USER',
     'Active user',
     'Charged per Active User per annum. An Active User retains active status, holds a valid current employment or training record, and can log in to consume training.',
     'per_unit_usage', 'none', 'Active User per annum', 200, 40),

    ('BESPOKE-COURSE',
     'Bespoke course development',
     'Development of a client-specific course, priced per course.',
     'one_off', 'none', 'course', 120000, 50)
) as v(code, name, description, billing_kind, recurrence, unit_label, price, sort_order)
left join public.profiles p on p.email = 'kemp.house+bespokelms@googlemail.com'
where o.slug = 'bespokelms'
on conflict (owning_organization_id, code) do nothing;
