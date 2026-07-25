# BespokeLMS — Learner experience: data contract

### For the learners-view build — how the learner side reads/writes the schema (migrations 003–010)

**Prepared:** 23 July 2026 · **Audience:** the agent building the learner-facing views (My workspace, course library, player, progress, certificates)

The purpose of this note is so the learner side builds on the **real** data model rather than reinventing it. Everything below already exists (or is a delivered, validated migration awaiting apply). Field names are the actual ones.

## The one rule that differs from the owner console

The platform-owner console reads with the **service-role key** (it spans all tenants, gated by route middleware). The **learner side must read with the signed-in user's token**, so Supabase **RLS** does the scoping. Do *not* use the service-role key for learner reads. RLS already guarantees a learner sees only their own records and only courses their tenant is entitled to — lean on it.

## 1. Course discovery / library

- **`courses`** — catalogue shell: `title`, `slug`, `hero_image_path`/`hero_image_alt`, `trailer_video_path`/`trailer_url`, SEO `meta_*`, `duration_min` (time to complete), `cpd_points`, `issues_certificate`, `catalog_status` (`published`/`coming_soon`/`retired`).
- **`course_versions`** — the *published* version supplies the learner-facing **descriptive copy** (staged there so learners never see mid-edit changes): `description`, `description_short`, `aims`, `aims_short`, `objectives`, `objectives_short` (fall back to `courses.description`). Use `courses.current_published_version_id` for the live version.
- **Visibility:** call/replicate **`can_see_course(course_id)`** — a learner only sees `global` courses + ones their tenant is entitled to (`course_visibility` / `course_entitlements`, migration 004). RLS already filters `courses` reads to this.
- **Tenant labels:** `resolve_course_title(course_id, org)` and `resolve_category_label(category_id, org)` (006) return the tenant's overridden title/category, else the global value.
- **Coming-soon:** when `catalog_status = 'coming_soon'`, show the placeholder + a "notify me" action → insert into **`course_notify_requests`** (`course_id`, `profile_id`/`email`).

## 2. Enrolment

- **`enrollments`** — `user_id`, `course_id`, **`course_version_id`** (the pin — render this exact version for the whole enrolment), `status`, `progress_pct`, `assigned_at`/`due_at`/`completed_at`, **`certificate_expires_at`**. A learner is locked to the version they started; a newly published version does not change an in-flight enrolment.
- **`course_requirements`** — which courses are mandatory for a role/team/org (drives "assigned to you").

## 3. Access & retake/retry gating (important — don't let a learner exceed policy)

- Read **`v_course_effective_pricing`** (007) for the course: `pricing_type`, `assessment_retry_limit` (`-1` = unlimited), `retake_after_pass` (`unlimited`/`none`/`limited`), `access_revoked_on_pass`.
- Before letting a learner **start / re-start** a course or **re-attempt** the assessment, check their **`course_attempts`** count against that policy:
  - subscription / included → unlimited attempts + retakes;
  - pay-as-you-go / one-off / credits → unlimited *retries to pass*, but `retake_after_pass = none` and `access_revoked_on_pass = true` (once passed, the course closes — re-purchase to take again).

## 4. Taking a course (the player)

- **`course_attempts`** (010) — one row per attempt/registration: `enrollment_id`, `attempt_no`, `registration_uuid` (also the cmi5 registration), `status`, `score_scaled`.
- **Native slide courses** → **`native_progress`** (per `slide_id`: `engaged`, `view_seconds`, `points`, `completed_at`). Content tree = `modules → lessons → slides` (003); slide `type` ∈ image_text/video/document with a jsonb `payload` + `completion_rule`.
- **Imported SCORM courses** (`course_versions.is_scorm`, package in **`scorm_packages`**) → **`scorm_tracking`** (CMI per SCO: `completion_status`, `success_status`, `score_*`, `location` = bookmark, `suspend_data` = resume blob). Replay `location`/`suspend_data` on resume.
- **`xapi_statements`** — emit cmi5/xAPI to the LRS store (launched/initialized/completed/passed/failed/terminated).
- **Writes are own-only:** RLS lets a learner write their own attempts/progress (`enrollment_is_own`); managers/admins can *read* their people's records (`enrollment_user_visible` / `visible_profile_ids`). No tenant can read another's.

## 5. Completion & certification

- On completion set the attempt `status` (`passed`/`completed`) and roll up to `enrollments`.
- If `courses.issues_certificate` → create a **`certificates`** row; validity from `courses.certificate_validity` (interval) → `enrollments.certificate_expires_at`. `issues_certificate = false` is valid (uncertified pathway step).
- Recert: when `certificate_expires_at` passes and `courses.auto_reassign_on_expiry`, the course is re-assigned (a scheduled job handles this + notifies via the notifications module). The learner UI should surface "renewal due".

## 6. Voiceover (migration 011, if applied)

- **`voiceover_assets`** — pre-generated narration audio per (slide, locale), served from Storage; the player plays it as an accessibility enhancement (user-initiated, pausable, with a matching transcript). `tenant_voice_profile` sets the per-tenant/brand voice.

## 7. Dashboards

- **`v_user_compliance`** (001) — per-user assigned/completed/overdue counts + `compliance_pct` for the learner's home dashboard. `v_team_compliance` / `v_org_compliance` for managers.

## Don'ts

- Don't read learner data with the service-role key — use the user's token + RLS.
- Don't render off `courses` content directly — render the **pinned `course_version`** and its `modules/lessons/slides` (or SCORM package).
- Don't let a learner exceed the effective retake/retry policy (§3).
- Don't assume marketing copy is on `courses` — the descriptive copy is on `course_versions` (007 revision).

## Apply status

These tables/views come from migrations **003–010** (and **011** for voiceover). They are validated but **not yet applied to Supabase** — coordinate on when they go live so the learner reads and the migrations land together. Until applied, expect the pre-migration fallback (the base `courses` columns from 001).
