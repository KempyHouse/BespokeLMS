-- ===========================================================================
-- BespokeLMS — Schema migration 011 (ElevenLabs voiceover)
-- Target: Supabase / Postgres.  Depends on 001–010.
--
-- Pre-generated narration for slides (accessibility / UDL). Audio is baked at
-- publish/approve time and cached by a content hash so re-publishing never
-- re-bills; served from Storage. Per-tenant/brand voice config, and a per-tenant
-- usage ledger (ElevenLabs bills ONE shared pool with no native tenant split,
-- so the platform meters and caps it here).
--
-- Additive + declarative. Validated on real Postgres 16 against 001–010.
-- ===========================================================================

-- ============================ ENUMS ========================================
create type voiceover_status as enum ('pending','generating','ready','failed','stale');

-- ===================== PER-TENANT / BRAND VOICE ===========================
-- One voice config per (tenant, locale). Fallback chain resolved in the app:
-- tenant+locale → tenant default (locale null) → platform default (org null).
create table tenant_voice_profile (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,  -- null = platform default
  locale          text,                                                 -- null = tenant default
  voice_id        text not null,
  model_id        text not null default 'eleven_multilingual_v2',
  voice_settings  jsonb not null default '{}'::jsonb,                   -- stability/similarity/style/…
  pronunciation_dictionary_id text,
  updated_by      uuid references profiles(id),
  updated_at      timestamptz not null default now(),
  unique (organization_id, locale)
);
create index on tenant_voice_profile(organization_id);

-- ===================== GENERATED NARRATION ASSETS =========================
-- content_hash = sha256(normalized_text + voice_id + model_id + locale +
-- serialized voice_settings [+ pronunciation dict + seed]). A hit = no API call,
-- no billing. Editing a slide/voice changes the hash → asset marked stale and
-- only that slide/locale is regenerated.
create table voiceover_assets (
  id                uuid primary key default gen_random_uuid(),
  organization_id   uuid references organizations(id) on delete cascade, -- tenant that owns/paid for it (null = platform)
  course_id         uuid references courses(id) on delete cascade,
  slide_id          uuid references slides(id) on delete cascade,
  locale            text not null default 'en',
  content_hash      text not null,
  source_text_ref   text,                       -- pointer/hash of the narrated text
  voice_id          text,
  model_id          text,
  voice_settings    jsonb not null default '{}'::jsonb,
  seed              bigint,
  storage_path      text,                       -- Supabase Storage (private)
  mime              text default 'audio/mpeg',
  duration_ms       int,
  byte_size         int,
  character_count   int,                        -- for metering
  timestamps_json   jsonb,                      -- word/char timings for synced captions
  status            voiceover_status not null default 'pending',
  elevenlabs_request_id text,
  created_at        timestamptz not null default now(),
  generated_at      timestamptz,
  unique (content_hash)
);
create index on voiceover_assets(organization_id);
create index on voiceover_assets(course_id);
create index on voiceover_assets(slide_id);
create index on voiceover_assets(status);

-- ===================== PER-TENANT USAGE LEDGER ============================
-- ElevenLabs has no native per-tenant metering, so the platform counts
-- characters server-side before dispatch and enforces a monthly cap per tenant.
create table tenant_voiceover_usage (
  organization_id uuid not null references organizations(id) on delete cascade,
  period          text not null,               -- 'YYYY-MM'
  characters_used bigint not null default 0,
  credits_used    numeric not null default 0,
  cap_characters  bigint,                       -- null = no cap (platform default applies)
  updated_at      timestamptz not null default now(),
  primary key (organization_id, period)
);

-- ========================= ROW-LEVEL SECURITY ==============================
alter table tenant_voice_profile   enable row level security;
alter table voiceover_assets       enable row level security;
alter table tenant_voiceover_usage enable row level security;

-- voice profiles: platform defaults owner-managed; tenant rows managed by an
-- admin in that org subtree; readable within the subtree (players resolve voice).
create policy voice_profile_read on tenant_voice_profile for select using (
  organization_id is null or organization_id in (select org_and_descendants(auth_org_id()))
);
create policy voice_profile_manage on tenant_voice_profile for all using (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
) with check (
  case when organization_id is null then auth_role() = 'bespokelms_owner'
       else is_admin() and organization_id in (select org_and_descendants(auth_org_id())) end
);

-- assets: readable if you can see the course; managed by whoever manages it
-- (privileged generation runs service-side). Platform-owned assets readable by all.
create policy voiceover_read on voiceover_assets for select using (
  course_id is null or can_see_course(course_id)
);
create policy voiceover_manage on voiceover_assets for all
  using ( course_id is not null and can_manage_course(course_id) )
  with check ( course_id is not null and can_manage_course(course_id) );

-- usage ledger: an org admin sees/manages their own subtree; owner sees all.
create policy vo_usage_read on tenant_voiceover_usage for select using (
  auth_role() = 'bespokelms_owner' or organization_id in (select org_and_descendants(auth_org_id()))
);
create policy vo_usage_manage on tenant_voiceover_usage for all
  using ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) )
  with check ( is_admin() and organization_id in (select org_and_descendants(auth_org_id())) );

-- ============================ GRANTS =======================================
grant select on tenant_voice_profile, voiceover_assets, tenant_voiceover_usage to anon, authenticated;
grant insert, update, delete on tenant_voice_profile, voiceover_assets, tenant_voiceover_usage to authenticated;

-- NOTE: generation is a server-side Laravel queue job (service-role) that runs
-- AFTER a locale's translation is human-approved, respects a global concurrency
-- semaphore (ElevenLabs concurrency is low + account-wide), counts characters
-- into tenant_voiceover_usage and enforces cap_characters before calling the
-- API, then stores the audio (private Storage) keyed by content_hash. The API
-- key stays server-side only. Voiceover is an accessibility ENHANCEMENT, not a
-- WCAG mechanism — pair with captions/transcripts and semantic markup.
