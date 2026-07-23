# BespokeLMS — Course Editor: field & schema specification

### Mapping the course-editor fields onto the database (extends migrations 003 + 006)

**Prepared:** 23 July 2026 · **Status:** schema spec / proposal (build-ready as migration `007`) · **Basis:** the requested editor field list, mapped to the live BespokeLMS schema

---

## 1. Purpose

The course editor needs a defined set of fields, database-backed. This document maps every requested field to a concrete place in the schema — reusing what `003` (courses/versions) and `006` (categories/tags) already provide, and designing the genuinely new pieces: **hero/trailer media, marketing copy with mobile-short variants, SEO metadata, categories/territories/authors, the pricing mechanism, the retake/retry rules that vary by pricing, and certification validity + auto-reassignment.** Names are illustrative; everything is snake_case, `timestamptz`, RLS-scoped, token-driven, consistent with `001`–`006`.

---

## 2. Where each field lives — the placement principle

The two-axis model (`003`) gives two homes:

- **`courses`** = the stable **identity + catalogue + commercial** shell. Things that sell and price the course and rarely change with a content revision live here: slug, hero image, trailer, marketing copy, SEO, categories/tags/territory, pricing, retake policy, certification policy, authors, coming-soon state.
- **`course_versions`** = the **content-specific** layer that changes per revision: the version number itself, assessment placement, and pass mark (these belong to a specific version of the content).

Rule of thumb applied below: *if it's about selling/pricing/finding the course → `courses`; if it's about this version's content/assessment → `course_versions`.* One decision to confirm (§8): whether the marketing copy (description/aims/objectives) should be overridable per major version — the default here keeps it on `courses` as canonical, editable in the editor.

---

## 3. Field-by-field mapping

| # | Field | Home → column | Type | Status |
|---|---|---|---|---|
| 1 | **Coming soon** placeholder + "notify me when live" | `courses.catalog_status = 'coming_soon'` (exists) + new `course_notify_requests` | enum + table | existing + new |
| 2 | Course title | `courses.title` | text | exists |
| 3 | Slug (auto from title, overridable) | `courses.slug` (unique; auto-generated in `003`, editable) | text | **exists** |
| 4 | Hero / cover image | `courses.hero_image_path` (Supabase Storage) | text | new |
| 5 | Hero image alt text | `courses.hero_image_alt` | text | new |
| 6 | Course trailer (upload + link) | `courses.trailer_video_path` (Storage) + `courses.trailer_url` (external, e.g. Vimeo/YouTube) | text ×2 | new |
| 7 | Course description | `courses.description` (exists) | text | exists |
| 8 | Description — short (mobile) | `courses.description_short` | text | new |
| 9 | Course aims | `courses.aims` | text | new |
| 10 | Aims — short (mobile) | `courses.aims_short` | text | new |
| 11 | Course objectives | `courses.objectives` | text | new |
| 12 | Objectives — short (mobile) | `courses.objectives_short` | text | new |
| 13 | Assessment location (between modules / at end / none) | `course_versions.assessment_placement` | enum `inline_between_modules \| end_of_course \| none` | new |
| 14 | Pass mark | `course_versions.pass_mark_pct` | int (0–100) | new |
| 15 | CPD / CE points | `courses.cpd_points` (+ `courses.cpd_body`); keep existing `credits`/`accreditation` | numeric + text | new (extends) |
| 16 | Course version number | `course_versions.semver` (+ internal `version_no`) | text/int | **exists** |
| 17 | **Pricing mechanism** (price / credits / subscription…) | new `course_pricing` (see §4) | table | new |
| 18 | Time to complete (estimate) | `courses.duration_min` (exists; display hrs/mins) | int (minutes) | exists |
| 19 | SEO / meta (search + AI discoverability) | `courses.meta_title`, `meta_description`, `meta_keywords` (+ hero as og:image) | text | new |
| 20 | Tags → categories (**Categories = owner-managed CRUD**) + territory | `categories`/`tags`/`course_tags` (`006`) + new `territories` + `course_territories` | tables | `006` + new |
| 21 | Author(s) (from dev module + roled users) | new `course_authors` (internal `profile_id` or external `display_name`) | table | new |
| 21b | Territory / jurisdiction | `territories` + `course_territories` (owner-managed vocabulary) | tables | new |
| 22 | **Certification** (cert on pass / none; validity → auto re-assign) | `courses.issues_certificate`, `certificate_validity` (interval), `auto_reassign_on_expiry`; ties to `certificates` + `enrollments.certificate_expires_at` (`003`) | bool/interval | new (extends) |
| 23 | **Retakes / retries** (vary by pricing) | `course_pricing.*` retake/retry rules + owner-set defaults per pricing type (see §5) | table | new |
| 24 | **Review date** (default 12 months from last publication) | `review_schedule.review_due_at` (`005`) + `course_versions.review_due_at`/`review_interval` (`003`); computed = last `published_at` + `review_interval` (default `12 months`) | date/interval | **exists** |

"There will be more tags in future" is handled by the extensible tagging model in §6.

---

## 4. Pricing mechanism (17)

Pricing is a first-class, platform-owner-configurable concern — not a single price column. Model it as a per-course `course_pricing` record whose shape covers every mechanism:

- `pricing_type` — enum: `free` | `one_off` (money) | `credits` | `included_in_subscription` | `pay_as_you_go`. (Extensible.)
- `price_pennies` (money), `currency`, `credit_cost` (credits) — used per type. (`courses.price_pennies`/`credits` from `001` migrate in.)
- `included_in_subscription` (bool) + future `subscription_plan_ids` (which plans grant it).
- Plus the retake/retry rules in §5.

A course can be free, one-off priced, credit-priced, bundled into a subscription, or PAYG — and the editor shows only the inputs relevant to the chosen `pricing_type`.

---

## 5. Retakes & retries — variable by pricing (23)

This is the subtle one, and it must be **owner-configurable**, with sensible defaults per pricing mechanism and per-course override. Two distinct concepts:

- **Assessment retries** = attempts to *pass* the assessment within an active enrolment. `assessment_retry_limit` — `null` = unlimited, or an integer N.
- **Retakes after pass** = whether a learner can redo the whole course *after* they've already passed. `retake_after_pass` — enum `unlimited` | `none` | `limited(N)`, plus `access_revoked_on_pass` (bool) for the PAYG "once you pass, it's done" behaviour.

Worked through your examples:

| Mechanism | Assessment retries | Retakes after pass | Access after pass |
|---|---|---|---|
| **Subscription / included** | unlimited | unlimited | retained while subscribed |
| **Pay-as-you-go** | unlimited (retry to pass) | none | **revoked on pass** (re-purchase to take again) |

So a subscriber can attempt the course and its assessment without limit; a PAYG learner can retry the assessment as many times as needed to pass, but once passed the course closes to them.

To make this "variable in the platform": a platform-owned **`pricing_defaults`** table holds the default retry/retake rules **per `pricing_type`** (the owner decides "PAYG = unlimited retries, no retakes, revoke on pass"), and each `course_pricing` row may **override** them. The runtime enrolment/access check reads the effective policy (course override → pricing-type default) to decide whether a learner may (re)start the course or (re)attempt the assessment. This composes with the existing `enrollments`/`course_attempts` model (`003`), which already tracks attempts.

---

## 6. Categories, territories & extensible tags (20, 21b)

- **Categories** are already a platform-owner-managed dictionary in `006` (`categories` + owner-only write RLS, with per-tenant overrides). The missing piece is the **CRUD UI** for the owner (create/rename/re-parent/reorder/retire) — a Phase-7 screen; the schema is done.
- **Territory / jurisdiction** is a new controlled vocabulary the owner manages: `territories` (code, name, parent for region→country nesting) + `course_territories` (course ↔ territory) so courses can be targeted to user groups by jurisdiction.
- **Future tag dimensions** are handled without schema churn by treating each controlled vocabulary as its own lookup + join (categories, territories, + the next one), alongside the free-form `tags`/`course_tags` from `006`. If the number of dimensions grows a lot, a single generic `tag_dimensions` + typed `taggables` table is the drop-in generalisation — noted as an option, not needed for day one.

Tag/category resolution stays tenant-overridable (`006`): the platform owns the canonical vocabulary; tenants can relabel/hide for their own library.

---

## 7. Authors, certification, coming-soon, media, SEO — the new tables/columns

- **Authors (21)** — `course_authors` (`course_id`, `profile_id` nullable for internal users with an author role, `display_name` nullable for external SMEs, `credit_label`, `sort`). Populated from the development module (`course_assignments` role = author, `005`) *and* manual entries, so the course-library "by …" credits work for both staff and guest authors.
- **Certification (22)** — on `courses`: `issues_certificate` (bool; false is valid — the course can be an uncertified pathway step), `certificate_validity` (interval; null = never expires), `auto_reassign_on_expiry` (bool). On expiry (via `enrollments.certificate_expires_at` + a scheduled job) the course is automatically re-assigned to the learner for recertification — the annual-refresh behaviour — and a notification is raised via the notifications module. This reuses the `certificates` table (`003`) and the review/recert clock already discussed.
- **Coming-soon notify (1)** — `course_notify_requests` (`course_id`, `email` or `profile_id`, `requested_at`, `notified_at`). While a course is `coming_soon`, the library shows a placeholder with a "notify me" action that inserts a request; when the course goes live, all pending requests are notified (notifications module) and stamped.
- **Media (4–6)** — hero image + alt + trailer (upload path in Supabase Storage and/or external URL). Private/public Storage bucket per your asset policy; served via the existing token-styled components.
- **SEO/meta (19)** — `meta_title`, `meta_description`, `meta_keywords`; the hero image doubles as the Open-Graph image. From these the app can also emit **schema.org `Course` structured data**, which helps both Google and AI search surface the courses.
- **Review date (24)** — already modelled: `review_schedule` (`005`) holds `review_interval` (default `12 months`) and `review_due_at`, and the migration backfilled `review_due_at = published_at + 12 months`. The editor should surface (and allow overriding) the interval and the computed date, **re-based on each official publication** — i.e. when a new version is published, `review_due_at` recomputes from that version's `published_at`. This is the same clock that feeds the tracker's "Live – Review Due Soon" stage and the recertification automation, and it is distinct from a learner's certificate expiry.

---

## 8. Schema sketch (migration 007 outline)

- **ALTER `courses`** — add: `hero_image_path`, `hero_image_alt`, `trailer_video_path`, `trailer_url`, `description_short`, `aims`, `aims_short`, `objectives`, `objectives_short`, `cpd_points`, `cpd_body`, `meta_title`, `meta_description`, `meta_keywords`, `issues_certificate` (bool default true), `certificate_validity` (interval), `auto_reassign_on_expiry` (bool default false). (`slug`, `description`, `duration_min`, `price_pennies`, `credits`, `accreditation`, `catalog_status` already exist.)
- **ALTER `course_versions`** — add: `assessment_placement` (enum), `pass_mark_pct` (int).
- **New enums** — `pricing_type`, `assessment_placement`, `retake_after_pass`.
- **New tables** — `course_pricing` (per-course pricing + retake/retry, FK course), `pricing_defaults` (platform-owned per-`pricing_type` default policy), `territories` + `course_territories`, `course_authors`, `course_notify_requests`.
- **Reuse** — `categories`/`tags`/`course_tags`/tenant overrides (`006`); `certificates` + `enrollments.certificate_expires_at` (`003`); `course_attempts` for retry counting (`003`); `notifications` module for notify-me + recert alerts.
- **RLS** — course-owned rows follow `can_manage_course` (`003`); `pricing_defaults` and `territories` are platform-owner-managed (like the `006` global dictionaries); `course_notify_requests` insert is open to authenticated browsers, read to course managers.

---

## 9. Decisions to confirm

- **Marketing copy placement** — keep description/aims/objectives (and their mobile-short variants) on `courses` as canonical (recommended, simpler editor), or make them overridable per major version?
- **Mobile-short variants** — explicit paired columns (recommended, 1:1 with editor fields) vs a single `marketing` jsonb blob?
- **Pricing defaults** — confirm the default retry/retake matrix per `pricing_type` (the §5 table) that the platform owner starts from.
- **Territory model** — dedicated `territories` vocabulary (recommended) vs treating jurisdiction as another free tag?
- **Trailer hosting** — upload to Supabase Storage, external URL only, or both (recommended: both)?
- **Certificate on expiry** — auto-reassign the course by default, or only when `auto_reassign_on_expiry` is set per course (recommended: opt-in per course)?

---

*Spec only — nothing built. It's written to be build-ready: on your confirmation of §9 (especially the pricing/retake defaults and copy placement), the next step is migration `007` extending `courses`/`course_versions` and adding the pricing, territory, author and notify tables, validated on Postgres the same way as `003`–`006`, then the editor form fields wired on top.*
