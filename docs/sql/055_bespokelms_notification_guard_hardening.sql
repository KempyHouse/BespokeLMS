-- 055_bespokelms_notification_guard_hardening.sql
--
-- Supabase security-advisor follow-ups on 050 and 051.
--
-- Two findings, both on the trigger functions those migrations added:
--
--   function_search_path_mutable — a function without a pinned search_path
--   resolves unqualified names against whatever the caller's path happens to
--   be, which is a privilege-escalation route when the function is SECURITY
--   DEFINER and a correctness hazard when it is not.
--
--   anon/authenticated_security_definer_function_executable — PostgREST
--   exposes every function in the public schema as an RPC endpoint, so
--   notification_preference_guard was callable at /rest/v1/rpc/... by any
--   signed-in user. A trigger function has no business being reachable that
--   way; nothing legitimate calls it directly.
--
-- The pre-existing rls_disabled_in_public findings on the consent_records
-- partitions belong to another migration line and are untouched here.

create or replace function outbound_template_classification_guard()
returns trigger
language plpgsql
set search_path = public
as $fn$
begin
  if old.is_classification_locked and new.category is distinct from old.category then
    raise exception 'template % has a locked classification (%) and cannot be reclassified', old.key, old.category
      using errcode = 'check_violation';
  end if;

  if old.is_classification_locked and new.is_classification_locked = false and old.is_protected then
    raise exception 'template % is protected; its classification lock cannot be released', old.key
      using errcode = 'check_violation';
  end if;

  new.updated_at := now();
  return new;
end;
$fn$;

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

revoke execute on function notification_preference_guard() from public, anon, authenticated;
revoke execute on function outbound_template_classification_guard() from public, anon, authenticated;
revoke execute on function invitations_touch() from public, anon, authenticated;
