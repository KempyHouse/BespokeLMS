-- 277: four published menu links had no role grant, so nobody could see them.
--
-- Found by the smoke suite (smoke_nav_links_have_a_role_grant) while verifying
-- release 2026.7.4, and filed as a bug report from the failing case. Same class
-- of fault as dev.documents, repaired in 276 — which is what prompted writing
-- the case that found these.
--
-- nav_item_visibility is grant-only: absence hides. A link with no row is
-- invisible to everybody including the platform owner, so the feature behind it
-- is live and unreachable from the navigation. Two of the four are the Learning
-- Pathways links that shipped the same morning.
--
-- Who each should be granted to is read off the siblings in the same group,
-- so the fix matches the menu's own intent rather than a guess:
--   admin-rail  / Your platform / admin.pathways                -> client_admin, lms_operator_admin
--   my-rail     / My workspace  / my.pathways                   -> all five roles, like my.home
--   app-header  / Account       / account.security              -> all five roles, like account.profile
--   app-header  / Account       / account.notification_settings -> all five roles, like account.preferences
--
-- Menus are versioned and published, never edited in place, so each of the
-- three menus is cloned, granted and published as a new version.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 277_navigation_links_without_a_grant.
--
-- The lasting fix is not this migration, it is the case: an ungranted link is
-- now a smoke failure at every release gate rather than something somebody
-- notices months later when a client asks where a feature went.

create or replace function pg_temp.clone_published_menu(p_menu_key text)
returns uuid language plpgsql as $fn$
declare v_menu uuid; v_old uuid; v_new uuid; v_next integer;
begin
    select id into v_menu from nav_menus where key = p_menu_key;
    if v_menu is null then raise exception 'No menu %', p_menu_key; end if;

    select id into v_old from nav_menu_versions where menu_id = v_menu and state = 'published';
    if v_old is null then raise exception 'Menu % has no published version', p_menu_key; end if;

    select coalesce(max(version_no), 0) + 1 into v_next from nav_menu_versions where menu_id = v_menu;

    insert into nav_menu_versions (menu_id, version_no, state, parent_route_key, back_label, back_mode)
    select menu_id, v_next, 'draft', parent_route_key, back_label, back_mode
      from nav_menu_versions where id = v_old
    returning id into v_new;

    create temp table if not exists clone_map (old_id uuid primary key, new_id uuid) on commit drop;
    delete from clone_map;

    with roots as (
        insert into nav_menu_items (version_id, parent_id, item_type, route_key, label, icon,
                                    badge_source, default_open, visible, sort_order, options)
        select v_new, null, item_type, route_key, label, icon,
               badge_source, default_open, visible, sort_order, options
          from nav_menu_items where version_id = v_old and parent_id is null
        returning id, route_key, sort_order, item_type, label
    )
    insert into clone_map (old_id, new_id)
    select o.id, r.id from nav_menu_items o
      join roots r on r.sort_order = o.sort_order and r.item_type = o.item_type
                  and o.route_key is not distinct from r.route_key
                  and o.label is not distinct from r.label
     where o.version_id = v_old and o.parent_id is null;

    with kids as (
        insert into nav_menu_items (version_id, parent_id, item_type, route_key, label, icon,
                                    badge_source, default_open, visible, sort_order, options)
        select v_new, cm.new_id, o.item_type, o.route_key, o.label, o.icon,
               o.badge_source, o.default_open, o.visible, o.sort_order, o.options
          from nav_menu_items o join clone_map cm on cm.old_id = o.parent_id
         where o.version_id = v_old
        returning id, parent_id, route_key, sort_order
    )
    insert into clone_map (old_id, new_id)
    select o.id, k.id from nav_menu_items o
      join clone_map cm on cm.old_id = o.parent_id
      join kids k on k.parent_id = cm.new_id and k.sort_order = o.sort_order
                 and k.route_key is not distinct from o.route_key
     where o.version_id = v_old
    on conflict (old_id) do nothing;

    insert into nav_item_visibility (item_id, role)
    select cm.new_id, nv.role from nav_item_visibility nv
      join clone_map cm on cm.old_id = nv.item_id
    on conflict do nothing;

    return v_new;
end;
$fn$;

create or replace function pg_temp.grant_link(p_version uuid, p_route_key text, p_roles text[])
returns void language plpgsql as $fn$
declare v_item uuid; r text;
begin
    select id into v_item from nav_menu_items
     where version_id = p_version and route_key = p_route_key and item_type = 'link';
    if v_item is null then raise exception 'No link % in that version', p_route_key; end if;

    foreach r in array p_roles loop
        insert into nav_item_visibility (item_id, role) values (v_item, r) on conflict do nothing;
    end loop;
end;
$fn$;

create or replace function pg_temp.publish_menu_version(p_version uuid)
returns void language plpgsql as $fn$
declare v_menu uuid;
begin
    select menu_id into v_menu from nav_menu_versions where id = p_version;
    update nav_menu_versions set state = 'superseded' where menu_id = v_menu and state = 'published';
    update nav_menu_versions set state = 'published', published_at = now() where id = p_version;
end;
$fn$;

do $$
declare
    v_admin uuid; v_my uuid; v_header uuid;
    everybody text[] := array['bespokelms_owner','lms_operator_admin','client_admin','team_manager','learner'];
begin
    v_admin := pg_temp.clone_published_menu('admin-rail');
    perform pg_temp.grant_link(v_admin, 'admin.pathways', array['client_admin','lms_operator_admin']);
    perform pg_temp.publish_menu_version(v_admin);

    v_my := pg_temp.clone_published_menu('my-rail');
    perform pg_temp.grant_link(v_my, 'my.pathways', everybody);
    perform pg_temp.publish_menu_version(v_my);

    v_header := pg_temp.clone_published_menu('app-header');
    perform pg_temp.grant_link(v_header, 'account.security', everybody);
    perform pg_temp.grant_link(v_header, 'account.notification_settings', everybody);
    perform pg_temp.publish_menu_version(v_header);
end $$;

do $$
declare v_ungranted integer; v_orphan integer; v_dupe integer;
begin
    select count(*) into v_ungranted
      from nav_menus m
      join nav_menu_versions v on v.menu_id = m.id and v.state = 'published'
      join nav_menu_items i on i.version_id = v.id and i.item_type = 'link'
     where not exists (select 1 from nav_item_visibility nv where nv.item_id = i.id);
    if v_ungranted > 0 then
        raise exception '% published link(s) still have no role grant', v_ungranted;
    end if;

    select count(*) into v_orphan from nav_menu_items c
      join nav_menu_items p on p.id = c.parent_id where c.version_id <> p.version_id;
    if v_orphan > 0 then raise exception '% cross-version parent(s)', v_orphan; end if;

    select count(*) into v_dupe from (
        select menu_id from nav_menu_versions where state = 'published'
         group by menu_id having count(*) > 1) t;
    if v_dupe > 0 then raise exception '% menu(s) with two published versions', v_dupe; end if;

    raise notice 'Every published menu link now carries at least one role grant.';
end $$;
