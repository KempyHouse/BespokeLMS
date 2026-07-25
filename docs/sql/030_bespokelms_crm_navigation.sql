-- 030: Sales CRM navigation — registry entries, module gating column, and the
-- managed crm-subrail menu (seeded as data; fully manageable in the CMS
-- Builder afterwards: labels, order, visibility, publish/rollback).
-- APPLIED to Supabase project pqmdtqsscyltykgcwwus on 2026-07-25 as
-- migration `bespokelms_crm_navigation_030` (via the Supabase MCP connector).
--
-- Adds route_registry.module_key: a destination gated on a tenant module is
-- only rendered for users whose organisation has that module enabled (the
-- per-tenant dimension feature_flags cannot express). The resolver applies
-- this per-request after the cached role-level structure.
-- The code-side source of truth (App\Support\Navigation\RouteRegistry +
-- nav:sync-registry) carries the same entries via the new 'module' field.

alter table route_registry add column if not exists module_key text;

comment on column route_registry.module_key is 'Tenant-module gate: when set, the destination renders only for users whose organisation has this module enabled in tenant_modules (checked per request by the NavigationResolver).';

-- ---- Registry: flip the CRM home live + add the CRM section entries -------

update route_registry
set route_type = 'page',
    route_name = 'crm.home',
    status = 'live',
    module_key = 'sales_crm',
    default_label = 'Sales CRM',
    description = 'Sales CRM overview — accounts, contacts, pipeline and communication timeline.',
    synced_at = now()
where key = 'ops.sales-crm';

insert into route_registry
  (key, route_type, route_name, status, scope, default_label, default_icon, description, module_key, sort_order, synced_at)
select v.key, v.route_type::nav_route_type, v.route_name, v.status::nav_route_status, 'operations'::nav_domain,
       v.label, v.icon, v.description, 'sales_crm', v.sort, now()
from (values
  ('ops.crm.accounts', 'page', 'crm.accounts', 'live', 'Accounts',
   '<path d="M3 21h18"/><path d="M5 21V7l8-4v18"/><path d="M19 21V11l-6-4"/><path d="M9 9h.01"/><path d="M9 12h.01"/><path d="M9 15h.01"/><path d="M9 18h.01"/>',
   'CRM accounts — companies and organisations in the owning tenant''s book of business.', 401),
  ('ops.crm.contacts', 'page', 'crm.contacts', 'live', 'Contacts',
   '<path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
   'CRM contacts — the people who work at accounts (many per account; one person may span several accounts).', 402),
  ('ops.crm.prospects', 'page', 'crm.prospects', 'live', 'Leads / Prospects',
   '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.35-4.35"/><path d="M11 8v6"/><path d="M8 11h6"/>',
   'Pre-customer view: contacts and accounts whose lifecycle stage is lead, MQL or SQL. A filtered view, not a separate object.', 403),
  ('ops.crm.deals', 'page', null, 'planned', 'Opportunities',
   '<path d="M12 2v20"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>',
   'Deals and pipelines (Phase 3): value, stage, forecast.', 404),
  ('ops.crm.activities', 'page', 'crm.activities', 'live', 'Activities',
   '<path d="M22 12h-4l-3 9L9 3l-3 9H2"/>',
   'The communication timeline and task list across the CRM: notes, calls, emails, meetings, tasks.', 405),
  ('ops.crm.segments', 'page', null, 'planned', 'Segments',
   '<circle cx="12" cy="12" r="10"/><path d="M22 12A10 10 0 0 0 12 2v10z"/>',
   'Contact segments for targeting (Phase 5); marketing sends are consent-checked at dispatch by the outbound module.', 406),
  ('ops.crm.imports', 'page', null, 'planned', 'Imports',
   '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="M7 10l5 5 5-5"/><path d="M12 15V3"/>',
   'Staged, dry-runnable CRM imports (Freshsales first), with dedup review and rollback by batch.', 407),
  ('ops.crm.settings', 'page', null, 'planned', 'CRM Settings',
   '<path d="M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z"/><circle cx="12" cy="12" r="3"/>',
   'Pipelines, retention, lifecycle defaults and module configuration.', 408)
) as v(key, route_type, route_name, status, label, icon, description, sort)
where not exists (select 1 from route_registry r where r.key = v.key);

-- ---- The crm-subrail managed menu ----------------------------------------

do $$
declare
  v_menu_id uuid;
  v_version_id uuid;
  v_group_sales uuid;
  v_group_audiences uuid;
  v_group_manage uuid;
  v_item uuid;
  v_roles text[] := array['bespokelms_owner','lms_operator_admin','client_admin','capability:sales'];
  r record;
begin
  if exists (select 1 from nav_menus where key = 'crm-subrail') then
    return;
  end if;

  insert into nav_menus (key, name, domain, menu_type, organization_id, notes)
  values ('crm-subrail', 'Sales CRM sub-rail', 'operations', 'sub_rail', null,
          'Left rail of the Sales CRM module. Items are gated by the sales_crm tenant module via the registry; visibility grants include the capability:sales pseudo-role.')
  returning id into v_menu_id;

  insert into nav_menu_versions (menu_id, version_no, state, published_at)
  values (v_menu_id, 1, 'published', now())
  returning id into v_version_id;

  insert into nav_menu_items (version_id, item_type, label, sort_order)
  values (v_version_id, 'group', 'Sales', 10) returning id into v_group_sales;
  insert into nav_menu_items (version_id, item_type, label, sort_order)
  values (v_version_id, 'group', 'Audiences', 20) returning id into v_group_audiences;
  insert into nav_menu_items (version_id, item_type, label, sort_order)
  values (v_version_id, 'group', 'Manage', 30) returning id into v_group_manage;

  for r in
    select * from (values
      ('ops.sales-crm',      10, 'sales',     'Overview'),
      ('ops.crm.accounts',   20, 'sales',     null),
      ('ops.crm.contacts',   30, 'sales',     null),
      ('ops.crm.prospects',  40, 'sales',     null),
      ('ops.crm.deals',      50, 'sales',     null),
      ('ops.crm.activities', 60, 'sales',     null),
      ('ops.crm.segments',   10, 'audiences', null),
      ('ops.crm.imports',    10, 'manage',    null),
      ('ops.crm.settings',   20, 'manage',    null)
    ) as t(route_key, sort, grp, label_override)
  loop
    insert into nav_menu_items (version_id, parent_id, item_type, route_key, label, sort_order)
    values (
      v_version_id,
      case r.grp when 'sales' then v_group_sales when 'audiences' then v_group_audiences else v_group_manage end,
      'link', r.route_key, r.label_override, r.sort
    ) returning id into v_item;

    insert into nav_item_visibility (item_id, role)
    select v_item, unnest(v_roles);
  end loop;
end $$;
