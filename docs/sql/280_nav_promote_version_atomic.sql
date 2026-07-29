-- 280: a menu can never be left with nothing live.
--
-- WHAT HAPPENED. Publish and rollback were two PATCHes from the app: demote
-- the published version, then promote its replacement. Migration 277's
-- publish-guard trigger can veto the promotion (error-severity drift), and on
-- 29 Jul it did — AFTER the demotion had already been written. The My-rail
-- menu ended with every version superseded, nothing published, and every
-- tenant's rail fell back to the built-in one. The state was repaired by
-- re-promoting v6 by hand; this migration removes the failure mode.
--
-- THE FIX IS A TRANSACTION, where the two writes always were one decision.
-- nav_promote_version() demotes and promotes inside a single function call.
-- The guard trigger still fires on the promotion and still vetoes exactly as
-- before — but a veto now rolls the demotion back with it, so the worst
-- outcome of a rejected publish is the state you started in.
--
-- The app's SupabaseNavigationAdmin::publish() and ::rollback() now call this
-- RPC instead of issuing the two PATCHes themselves.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-29.

create or replace function public.nav_promote_version(
    p_menu_id uuid,
    p_version_id uuid,
    p_published_by uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_found boolean;
begin
    select true into v_found
      from nav_menu_versions
     where id = p_version_id and menu_id = p_menu_id
       for update;

    if v_found is not true then
        raise exception 'No such version on that menu.';
    end if;

    update nav_menu_versions
       set state = 'superseded'
     where menu_id = p_menu_id
       and state = 'published'
       and id <> p_version_id;

    update nav_menu_versions
       set state = 'published',
           published_at = now(),
           published_by = coalesce(p_published_by, published_by)
     where id = p_version_id;
end;
$$;

comment on function public.nav_promote_version(uuid, uuid, uuid) is
    'Atomically supersede the published version of a menu and promote another in its place. The publish-guard trigger still vetoes a version with error-severity drift - and because both updates share this transaction, a veto rolls the demotion back too, so a menu can never be left with nothing live.';

revoke all on function public.nav_promote_version(uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function public.nav_promote_version(uuid, uuid, uuid) to service_role;
