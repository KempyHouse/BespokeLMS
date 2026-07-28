-- 270: Proposals & e-signature — navigation.
--
-- Registry entries for the esign module pages (mirrored code-side in
-- App\Support\Navigation\RouteRegistry and re-synced on every deploy by
-- nav:sync-registry) and the managed esign-subrail menu, seeded as data and
-- fully manageable in the CMS Builder afterwards. Follows 030 (crm-subrail)
-- exactly: items gated by the esign tenant module via the registry;
-- visibility grants include the capability:sales pseudo-role, because
-- proposals are a sales tool.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 270_bespokelms_esign_navigation.

insert into route_registry
  (key, route_type, route_name, status, scope, default_label, default_icon, description, module_key, sort_order, synced_at)
select v.key, v.route_type::nav_route_type, v.route_name, v.status::nav_route_status, 'operations'::nav_domain,
       v.label, v.icon, v.description, 'esign', v.sort, now()
from (values
  ('ops.esign', 'page', 'esign.home', 'live', 'Proposals & e-sign',
   '<path d="m12 19 7-7 3 3-7 7-3-3z"/><path d="m18 13-1.5-7.5L2 2l3.5 14.5L13 18l5-5z"/><path d="m2 2 7.586 7.586"/><circle cx="11" cy="11" r="2"/>',
   'Proposals & e-signature overview — envelopes in flight, awaiting approval, awaiting signature.', 420),
  ('ops.esign.documents', 'page', 'esign.documents', 'live', 'Documents',
   '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M16 13H8"/><path d="M16 17H8"/>',
   'Every envelope: draft, in approval, out for signature, completed, declined.', 421),
  ('ops.esign.templates', 'page', 'esign.templates', 'live', 'Templates',
   '<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 3v18"/><path d="M13 8h5"/><path d="M13 12h5"/>',
   'Reusable proposal templates with CRM merge fields; platform catalogue plus the tenant''s own library.', 422)
) as v(key, route_type, route_name, status, label, icon, description, sort)
where not exists (select 1 from route_registry r where r.key = v.key);

-- ---- The esign-subrail managed menu ---------------------------------------

do $$
declare
  v_menu_id uuid;
  v_version_id uuid;
  v_group_proposals uuid;
  v_group_manage uuid;
  v_item uuid;
  v_roles text[] := array['bespokelms_owner','lms_operator_admin','client_admin','capability:sales'];
  r record;
begin
  if exists (select 1 from nav_menus where key = 'esign-subrail') then
    return;
  end if;

  insert into nav_menus (key, name, domain, menu_type, organization_id, notes)
  values ('esign-subrail', 'Proposals & e-sign sub-rail', 'operations', 'sub_rail', null,
          'Left rail of the Proposals & e-signature module. Items are gated by the esign tenant module via the registry; visibility grants include the capability:sales pseudo-role.')
  returning id into v_menu_id;

  insert into nav_menu_versions (menu_id, version_no, state, published_at)
  values (v_menu_id, 1, 'published', now())
  returning id into v_version_id;

  insert into nav_menu_items (version_id, item_type, label, sort_order)
  values (v_version_id, 'group', 'Proposals', 10) returning id into v_group_proposals;
  insert into nav_menu_items (version_id, item_type, label, sort_order)
  values (v_version_id, 'group', 'Manage', 20) returning id into v_group_manage;

  for r in
    select * from (values
      ('ops.esign',           10, 'proposals', 'Overview'),
      ('ops.esign.documents', 20, 'proposals', null),
      ('ops.esign.templates', 10, 'manage',    null)
    ) as t(route_key, sort, grp, label_override)
  loop
    insert into nav_menu_items (version_id, parent_id, item_type, route_key, label, sort_order)
    values (
      v_version_id,
      case r.grp when 'proposals' then v_group_proposals else v_group_manage end,
      'link', r.route_key, r.label_override, r.sort
    ) returning id into v_item;

    insert into nav_item_visibility (item_id, role)
    select v_item, unnest(v_roles);
  end loop;
end $$;
