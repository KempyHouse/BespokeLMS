-- 085: what is actually loading on a tenant's website.
--
-- THE PROBLEM THIS SOLVES. The blocking engine matches on declared vendor
-- hosts. A tracker nobody wrote down is held (elements fail closed) but is
-- never named, so the tenant's vendor list drifts away from their real site
-- one marketing tag at a time, and the first anyone hears of it is a console
-- warning nobody reads. Worse, a third-party script placed ABOVE our tag in
-- the HTML cannot be blocked at all, and that is invisible from the console
-- of a person who never opens the console.
--
-- WHY NOT A CRAWLER. The obvious answer is to fetch the tenant's pages and
-- parse the HTML for <script src>. That finds the tags a crawler can see and
-- misses the ones that matter: essentially every tag manager inserts its
-- payload from script at runtime, on pages behind a login, after a consent
-- interaction, or only for some visitors. A crawl would produce a confident,
-- short and wrong list.
--
-- So the observation comes from the runtime, in real browsers, on real pages.
-- It sees what actually loaded because it is the thing that held it back.
--
-- WHAT IS AND IS NOT RECORDED. A hostname, a path, a count and two
-- timestamps. No consent id, no cookie, no address, no user agent, nothing
-- that is about the visitor rather than the website. This table has to be
-- explainable in one sentence to somebody who has just been told the point of
-- the module is to stop unnecessary data collection: it records which servers
-- a page contacts, not who was looking at it.
--
-- One row per (site, host, kind) forever: an upsert increments a counter, so
-- the table stays the size of the tenant's tag list rather than the size of
-- their traffic.

create table public.consent_observations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  site_id uuid not null references public.consent_sites(id) on delete cascade,

  host text not null,

  -- undeclared  — a third party contacted from a page, not in the vendor list.
  -- above_tag   — a third-party script the parser reached before our tag, which
  --               means it CANNOT be blocked. A different and more urgent
  --               problem than an undeclared host, so it is not the same row.
  kind text not null check (kind in ('undeclared', 'above_tag')),

  page_path text,
  hits integer not null default 1,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),

  -- new       — needs a decision.
  -- declared  — now in the vendor list; kept so it does not reappear as news.
  -- ignored   — deliberately left alone (a first-party CDN on another domain,
  --             say). Recorded rather than deleted, because "we looked at this
  --             and decided" is worth more than a row that quietly returns.
  status text not null default 'new' check (status in ('new', 'declared', 'ignored')),
  reviewed_by uuid references public.profiles(id) on delete set null,
  reviewed_at timestamptz,

  constraint consent_observations_unique unique (site_id, host, kind)
);

create index consent_observations_site on public.consent_observations (site_id, status, last_seen_at desc);

alter table public.consent_observations enable row level security;

-- Org-exact, with no platform-owner bypass, exactly as the rest of this
-- module: the tenant is the controller of what their own website does.
create policy consent_observations_select on public.consent_observations
  for select using (organization_id = auth_org_id());

create policy consent_observations_update on public.consent_observations
  for update using (organization_id = auth_org_id())
  with check (organization_id = auth_org_id());

/*
 * The write path.
 *
 * A function rather than a PostgREST insert because the upsert has to
 * INCREMENT a counter, and merge-duplicates cannot. It is also the reason
 * there is no INSERT policy on the table: the only way a row is created is
 * through here, where the organisation is taken from the site rather than
 * from anything the caller sent.
 *
 * That last point is the whole security model. This is called from an endpoint
 * an anonymous browser can reach, so a caller-supplied organisation would let
 * anybody write rows into any tenant's console.
 */
create or replace function public.record_consent_observation(
  p_site_key text,
  p_host text,
  p_kind text,
  p_page_path text default null
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_site consent_sites%rowtype;
  v_host text;
begin
  select * into v_site from consent_sites where site_key = p_site_key and status = 'live';

  if not found then
    return;
  end if;

  if p_kind not in ('undeclared', 'above_tag') then
    return;
  end if;

  -- Hostnames only. The caller is a browser, so this is untrusted input that
  -- becomes a row somebody reads and acts on; anything that is not a hostname
  -- is dropped rather than stored and displayed.
  v_host := lower(btrim(coalesce(p_host, '')));

  if v_host !~ '^[a-z0-9]([a-z0-9-]{0,62}\.)+[a-z]{2,63}$' or length(v_host) > 253 then
    return;
  end if;

  insert into consent_observations (organization_id, site_id, host, kind, page_path)
  values (v_site.organization_id, v_site.id, v_host, p_kind, left(coalesce(p_page_path, ''), 300))
  on conflict (site_id, host, kind) do update
    set hits = consent_observations.hits + 1,
        last_seen_at = now(),
        -- A host that reappears after being dealt with is news again. One that
        -- was ignored stays ignored: that was a decision, not an oversight.
        status = case when consent_observations.status = 'declared' then 'new' else consent_observations.status end;
end;
$$;

revoke all on function public.record_consent_observation(text, text, text, text) from public, anon, authenticated;
grant execute on function public.record_consent_observation(text, text, text, text) to service_role;
