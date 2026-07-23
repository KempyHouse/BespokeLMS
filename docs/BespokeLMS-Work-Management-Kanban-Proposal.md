# BespokeLMS — Work Management & Kanban module

### Design proposal: a tenant- and role-aware task/pipeline engine (Course Tracker and beyond)

**Prepared:** 23 July 2026 · **Status:** concept / architecture proposal (no code) · **Basis:** the TeachHQ "Course Tracker" spec, analysed against the live BespokeLMS schema and Laravel codebase

---

## 1. What you asked for

A tenant- and user-role-specific **task management system** — task lists *and* Kanban boards — that serves several "applications":

- **Course production** — the idea → backlog → writing → upload → voiceover → live pipeline in the Course Tracker spec (design, development, approval, sign-off, review).
- **Client idea intake** — gathering ideas from clients into a **backlog**, which is then combed, prioritised, and pulled into **sprints** to ship as courses/features.
- **Other applications** — e.g. a **Marketing** deal pipeline (closing deals through stages), and general team tasks.

Two placements: a **central task-management module** (not yet built) that spans everything, and a **filtered task view embedded inside the Course Management module** (the tracker for course production specifically). All stages and boards must be **configurable**, because the same engine drives many pipelines. Notifications must be delivered through a **separate notifications module**, not reimplemented here. Field names below are illustrative — the point is the shape, and everything must fit the existing Laravel + Supabase/Postgres architecture, multi-tenancy, RBAC and design-token system.

This is a **proposal only** — nothing is built. It analyses how the Course Tracker's behaviour maps onto what BespokeLMS already has, and recommends one coherent module rather than a standalone tracker.

---

## 2. The core insight: you already have half of this

Before proposing anything new, here's what the current system already provides that the tracker needs:

| Course Tracker concept | Already in BespokeLMS | Where |
|---|---|---|
| Configurable, ordered **workflow stages** with entry automation | `workflow_states` + `workflow_transitions` (data-driven, global default + per-tenant, `is_initial`/`is_published`/`is_terminal`, `requires_distinct_actor`, `required_capability`) | migration `005` |
| Per-item **current stage** + **audit trail** | `course_workflow_state` + `course_workflow_history` (from/to state, actor, comment, timestamp) | `005` |
| **Assignee** roles (author/reviewer/approver) | `course_assignments` (per-course user × role) | `005` |
| **Sign-off / approval** records | `course_approvals` (immutable decision + comment + signed_at) | `005` |
| **Review-due** dates + cron to flag them | `review_schedule` (interval, `review_due_at`, `next_reminder_at`) | `005` |
| Stage-gating **checklists** | `workflow_checklist_items` + `workflow_checklist_results` | `005` |
| **Client idea backlog** with votes | `ideas` (org-scoped, status idea/planned/in_progress/released, votes) + `idea_votes` | `001` |
| **Saved views** (filter/column subsets) | `saved_views` (owner/org, visibility, `state` jsonb) | `001` |
| **Notifications** | `notifications` table (per-user, type/title/body/link/read) — the seed of the separate notifications module | `001` |
| **Audit log** (generic) | `audit_log` (actor, org, action, entity, meta) | `001` |
| **Course** subject the tracker tracks | `courses` (identity shell) + `course_versions` | `003` |

So the Course Tracker is not a new subsystem — it is the **generalisation of migration `005`'s workflow engine into a polymorphic, board-based work-management layer**, with the `ideas` table as its client-intake front door and `saved_views`/`notifications`/`audit_log` reused as-is. The single most important recommendation in this document follows from that (see §12).

---

## 3. The core idea: one generic engine, many boards

Build **one** work-management module. Everything else is configuration.

- A **board** (a.k.a. pipeline) is a configurable Kanban/list for one *application* in one tenant — "Course Production", "Client Ideas", "Marketing — Deal Pipeline", "General Tasks". Boards can be seeded from **templates** (a platform-default Course Production board that every tenant inherits) and customised per tenant.
- A board has ordered **stages** (the Kanban columns) — fully configurable in name, order, colour tokens, WIP behaviour, default assignee, notify list, and **entry automation** (§9).
- A **work item** is a card: it lives in one stage of one board, has a priority, an assignee, dates, notes, links, and a flag. Crucially it is **polymorphic** — an item can *be about* a course, an idea, a marketing deal, or nothing at all (a standalone task). That polymorphism is what lets the same engine drive the Course Tracker and the Marketing pipeline.
- **Views** are the surfaces: a **Kanban board view** (drag cards between stages) and a **task-list view** (the inline-editable grid from the spec, built on your existing data-table). Both read the same items; saved views store the column/filter/stage subset.

Because items are polymorphic and boards are per-tenant configuration, the "central task module" and the "filtered view inside Course Management" are the *same data* seen through different scopes: the central module shows all boards a user can see; the Course Management module shows only the Course Production board(s), pre-filtered to the courses in view.

```
work_application         (course_production | client_ideas | marketing | generic …)
  └─ board / pipeline     (per tenant; from a template; configurable)
       └─ board_stage      (Kanban column; order, colour tokens, automation, default assignee)
            └─ work_item    (card: stage, priority, assignee, dates, notes, links, flag, archived)
                 └─ subject (polymorphic → course | idea | deal | none)
```

---

## 4. How each Course Tracker feature maps

Walking the spec against the proposed engine, so nothing is lost:

**Tracker grid (inline-editable data-grid).** The task-list view = your existing `<x-data-table>` component with inline-edit cells (stage dropdown, priority dropdown, inline date pickers) writing through to the item. Colour-coded platform/stage/priority cells use **design tokens** per stage/priority config (never fixed hex). Set-vs-unset date emphasis becomes a semantic token state. Header "Processed/Errors" counters come from bulk-add feedback. Row actions: assign+notify, notes indicator, archive, view-log, link icons.

**Kanban view.** The same items rendered as columns-by-stage with drag-to-move; moving a card = a stage transition (which fires automation, §9, and writes a log row). This is the new UI piece; everything behind it is the shared engine.

**Stages / workflow.** `board_stages` generalises `workflow_states`. The spec's 14 stages (Idea/Suggested → Backlog → Live-Review-Due-Soon → In planning → Writing → … → Approved-Live → Not Approved → Review Required) become the **seeded template** for the Course Production board — admin-configurable and reorderable, exactly as `005` already models.

**Priorities.** A configurable `priorities` list (Highest→Lowest) with order + colour tokens, per board or per tenant. Traffic-light tokens, not hex.

**Saved views & tabs.** Reuse `saved_views` — its `state` jsonb already stores scope/view/sort/filters; extend to hold selected columns + stage filter + button order. Seed the spec's views (Course In-Progress, Backlog, Ideas & Suggested, All Live, Everything) as default board views.

**Ad-hoc filter bar.** Free-text partial match across item fields (Postgres `pg_trgm`, already enabled in `003`); the add-course textarea copies titles into the filter for duplicate-spotting. Roadmap OR-logic and relative-date variables (`[today ± n]`) are a filter-grammar extension.

**Add / edit / bulk / duplicate detection.** Add modal with **bulk add** (one title per line → many items in one action), initial stage + priority, SharePoint/course links. Duplicate detection = fuzzy title match (`pg_trgm` similarity) surfacing existing items with age/status/link — design the service now, ship the prompt in phase 1.5.

**Per-stage automation (the defining feature).** `stage_automation` rules that fire on *entering* a stage: notify assignee, notify recipient list, set default assignee, stamp `upload_date`, stamp/compute `review_date`, branch to another stage, set priority. Stored as **config rows**, executed by a small rules engine — not hardcoded controller logic. This directly generalises `005`'s transition guards.

**Notifications.** Delivered through the **separate notifications module** (built on the existing `notifications` table), which this engine calls via an event/interface — it never sends directly. Channel-aware (in-app/email now; WhatsApp later) is the notifications module's concern.

**Cron / review-due automation.** Generalises `review_schedule` + its scheduled job: when a live item is within *N* days of `review_date`, move it to a review stage and set a flag. Offset days / branch stage / flag text are **config** (a cron-rule row), not constants.

**Archive / soft-delete + purge.** Items carry `archived` + `archived_at` (never hard-delete); an Archive Management screen lists/restores/permanently-deletes; a purge job removes items past a **configurable retention** (default 6 months).

**Notes & @mentions.** A per-item note (rich text) with `@mention` parsing that raises notifications via the notifications module; roadmap note-tags for filtering.

**Audit log (View Log).** `work_item_log` = immutable snapshot per change (timestamp, actor, before/after values, and a **source**: manual / automation / scheduled / restore). Improves on the source tool by logging platform/title changes from day one. Row-level "View Log" opens a modal or detail page. The generic `audit_log` can carry a coarse cross-entity trail; `work_item_log` holds the field-level detail.

**Reporting + scheduling.** `report_definitions` (name, tag, description, active, filter rows of field/operator/value/group with date-aware relative operators) + `report_schedules` (User × Report × Weekday, enable/disable, test-send, send-now) → recurring digests grouped by priority, delivered via the notifications module.

---

## 5. Ideas → backlog → sprint → live

This is the flow you emphasised, and it threads existing pieces together:

1. **Intake.** Clients submit ideas (the existing `ideas` table / `idea_votes` for demand signal). Each idea can be promoted into a work item on the **Client Ideas** board at stage *Idea / Suggested*.
2. **Backlog.** Evaluated ideas move to *Backlog* (parked, awaiting prioritisation); rejected ones are archived. Priority is set during grooming (default Medium on entry).
3. **Combing / prioritisation.** The Backlog view sorts by priority + demand (votes) for grooming.
4. **Sprint.** Selected items are pulled into a **sprint** (a time-boxed set) — a `sprints` container with `sprint_items`. A course/feature added to a sprint gets worked through the production stages.
5. **Live.** On completion the item reaches *Approved - Live / Published*; if it's a course, its polymorphic subject links to the real `courses`/`course_versions` record so the tracker and the catalogue stay in sync. Review-due automation later cycles it back for re-review.

So a single item can travel Ideas board → (promote) → Course Production board → (link) → a real course. Sprints give you the "comb the backlog, commit a batch, ship it" cadence.

---

## 6. Tenant & role scoping

Everything is tenant-scoped and RLS-enforced, exactly like the rest of the platform:

- Every board, stage, item, note, log and view carries `organization_id` (or resolves to one via the board) and is protected by **Row-Level Security** cascading down the org tree — the same `org_and_descendants` / `auth_org_id` / `is_admin` helpers already in use. A tenant can never see another tenant's boards or cards.
- **Board membership / visibility** governs *who within a tenant* sees a board (e.g. the Marketing board is visible to marketing roles, the Course Production board to content roles). A lightweight `board_members` (user × board × board-role: viewer / contributor / manager) layered on top of the platform `app_role` gives the "user-role-specific" behaviour you asked for.
- **Assignment** uses `profiles`; assignees must be members of the board's tenant subtree. Automation that reassigns respects the same boundary.
- The **platform owner** sees across tenants (for template management and support), consistent with the existing owner console.

---

## 7. Proposed data model (concept sketch — names illustrative)

Grouped by concern. This is a shape, not DDL; the real migration would be declarative, snake_case, `timestamptz`, RLS-on-every-table, matching `001`–`006`.

**Boards & configuration**

- `work_applications` — enum/table: `course_production`, `client_ideas`, `marketing`, `generic` (extensible).
- `boards` — `organization_id` (null = platform template), `application`, `name`, `is_template`, `template_id` (origin), `retention_days`, `created_by`.
- `board_stages` — `board_id`, `key`, `label`, `sort`, `colour_bg_token`, `colour_text_token`, `is_initial`/`is_terminal`/`is_live`, `default_assignee`, `wip_limit` (nullable).
- `board_stage_transitions` — optional gating: `from_stage_id`, `to_stage_id`, `requires_distinct_actor`, `required_capability`, `checklist_required` (bool).
- `priorities` — `board_id` (or org/global), `label`, `sort`, `colour_bg_token`, `colour_text_token`.

**Work items & subject**

- `work_items` — `board_id`, `stage_id`, `priority_id` (nullable), `assignee_id` (nullable), `title`, `flag` (nullable), `notes` (rich text), `target_go_live`, `upload_date`, `review_date`, `last_updated_at`, `source_link`, `output_link`, `archived`, `archived_at`, `created_by`.
- `work_item_subjects` — polymorphic link: `work_item_id`, `subject_type` (`course` | `idea` | `deal` | `none`), `subject_id`. (Keeps `work_items` generic; a course card points at a `courses.id`.)
- `work_item_notes` — `work_item_id`, `author_id`, `body`, `tags` jsonb (roadmap), `created_at` — with `@mention` parse raising notifications.
- `work_item_log` — immutable: `work_item_id`, `actor_id`, `changed_fields` jsonb (before/after), `source` (manual/automation/scheduled/restore), `at`.

**Automation & scheduling**

- `stage_automation` — `stage_id`, `action` (notify_assignee | notify_list | set_assignee | stamp_upload | stamp_review | branch_to | set_priority), `params` jsonb, `sort`.
- `stage_notify_recipients` — `stage_id`, `profile_id` (the additional notify list).
- `board_review_rules` (cron config) — `board_id`, `days_offset`, `branch_stage_id`, `flag_text`, `enabled` (generalises `review_schedule`'s job).

**Sprints**

- `sprints` — `board_id` (or tenant), `name`, `starts_on`, `ends_on`, `goal`, `status`.
- `sprint_items` — `sprint_id`, `work_item_id`, `committed_at`.

**Views, reporting, membership**

- reuse **`saved_views`** — extend `state` jsonb for columns + stage filter + button order + board_id.
- `report_definitions` — `board_id`/tenant, `name`, `tag`, `description`, `active`, `filters` jsonb (field/operator/value/group rows).
- `report_schedules` — `report_id`, `profile_id`, `weekdays`, `enabled`.
- `board_members` — `board_id`, `profile_id`, `board_role` (viewer/contributor/manager).

**Reuse / retire from migration `005`** — see §12.

---

## 8. UI surfaces (reusing what exists)

- **Task-list view** = the existing `<x-data-table>` with inline-edit cells + the toolbar (search, filter dropdowns, saved-view tabs, bulk actions) you already have — so it matches Tenants/Courses instantly and inherits the row-actions/z-index fixes just shipped.
- **Kanban view** = a new token-styled board component (columns = stages, cards = items, drag-to-transition). This is the main net-new UI; it shares the item service with the list view.
- **Central Task module** = a new top-level area (its own route group), listing every board the user can see, with a board switcher — analogous to the Platform console shell.
- **Embedded course tracker** = the Course Management module renders the Course Production board **pre-filtered** to the courses in scope (a "Tracker" tab on the Global Courses page, or in the course workspace). Same engine, scoped query.
- **Marketing pipeline** later = the same Kanban/list over a `marketing` board whose items' subject is a deal — no new engine, just a board config + a deal subject type.
- Everything is 100% **design-token** styled (stage/priority colours are tokens), WCAG 2.2 AA, responsive, mobile-first — with the Kanban board directing very small screens to a list view rather than degrading.

---

## 9. The automation engine (event-driven, config not code)

The tracker's power is that *entering a stage* can reassign, timestamp, notify, re-prioritise, and branch — automatically. Model it as an **event → rules** loop:

1. A stage change (manual inline edit, Kanban drag, or a scheduled job) raises a `StageEntered(work_item, from, to, actor)` domain event.
2. A handler loads that stage's `stage_automation` rows and applies them in order: stamp dates, set default assignee/priority, then **branch** (which can re-enter the loop once, guarded against cycles).
3. Each mutation writes a `work_item_log` row with `source = automation`.
4. Notification actions are dispatched to the **notifications module** (never sent inline), which owns channel/delivery.

Transitions can be **gated** by a checklist (reusing the `005` checklist pattern) — the card can't leave a stage until required items are ticked. This keeps the pipeline declarative: operators reconfigure behaviour by editing rows, not code.

---

## 10. Integration with existing modules

- **Notifications module (separate).** This engine depends on a notifications *interface* — `notify(recipients, event, payload)` — implemented by the notifications module over the existing `notifications` table (and future email/WhatsApp channels). The work-management module raises events; it does not format or deliver messages. This honours your "notifications must align with a separate module" requirement and keeps channels swappable.
- **Course Management.** A Course Production card's subject links to `courses.id`; when a course is created in the catalogue it can auto-open a tracker card, and when a card reaches *Approved-Live* it can flip the course's `catalog_status`/publish its version. The card's production stages sit *above* the `003`/`005` version-editorial states (which stay the fine-grained "one writes, another approves" per-version approval inside the editor).
- **Ideas.** The existing `ideas`/`idea_votes` feed the Client Ideas board (promotion + demand signal).
- **Audit.** `audit_log` keeps the coarse cross-module trail; `work_item_log` holds field-level history for the View Log screen.

---

## 11. Compatibility with the existing stack

The design stays inside every standard already in force: Laravel (thin controllers, Form Requests, Eloquent-first, RESTful, Pint/PSR-12); Supabase/Postgres (snake_case, `timestamptz`, declarative RLS migrations, `pg_trgm` for fuzzy match); service-role readers behind owner/tenant middleware with RLS as defence-in-depth; **design tokens only** (stage/priority colours are tokens defined before use); the reusable data-table for the list view; and the same additive-migration pattern as `003`–`006`. Nothing here requires a new architectural primitive — it reuses the org tree, RBAC helpers, RLS, tokens, notifications table, and the data-table.

---

## 12. Key recommendation: generalise migration 005, don't duplicate it

The one decision that determines whether this stays clean: **`005` is the course-specific seed of exactly this engine.** You have two coherent options.

- **Option A — Generalise (recommended).** Lift `workflow_states` / `workflow_transitions` / `course_workflow_state` / `course_workflow_history` / `course_assignments` / checklist into the **polymorphic board engine** (boards → stages → items → log, with assignments and checklists on items). The Course *editorial* approval (draft→in review→approved→published, per `course_version`) becomes one board template; the Course *production* tracker (idea→…→live, per `course`) becomes another; Marketing becomes a third. One stage engine, many boards. Because `005` is **written but not yet applied to Supabase**, this is the moment to do it — with near-zero rework, and it avoids ever running two parallel stage engines.
- **Option B — Coexist.** Keep `005` as the per-version editorial workflow and add the generic board engine alongside, with the Course Production board linking to courses. Less up-front change, but two stage engines to maintain and reconcile forever.

Recommendation: **Option A**, folding `005`'s generic pieces into the new engine and keeping only the genuinely course-specific bits (`course_approvals` sign-off records, `review_schedule`) as course extensions. Since none of `005`/`006` is applied yet, revising the migration set now is cheap and leaves you with a single, reusable work-management foundation.

---

## 13. Change management — classifying minor vs major changes

A change to a *published* course must be **classified**, because the classification decides how much process it triggers and whether learners are affected. This sits directly on top of the version model already in migration `003` (semver, `changelog`, `version_migration_policy`).

- **Minor** = a correction with no change to meaning — a spelling fix, an asset swap, a broken-link repair. A `1.x` bump; no learner impact; fast-track approval; edit-in-place feel.
- **Major** = a change that contextually alters the learning — e.g. major sections rewritten because **new legislation** landed. A `2.0` bump: a new immutable version, full editorial approval (separation of duties + checklist, from `005`), and a learner-impact decision.

Model it as a **change record** raised when someone opens a published course to edit it, capturing: `classification` (minor/major), a `category` (typo | asset | factual_correction | **legislative_update** | restructure | other), a `reason`, a short `summary`, and the affected sections. That record becomes the version's `changelog` plus an auditable row, and drives behaviour:

- **Minor** → small version bump, publish, notify only the team (or no one); learners keep going uninterrupted.
- **Major** → new major version; full sign-off; then per `version_migration_policy` either **finish-then-switch** (in-flight learners complete the old version, new enrolments get the new one) or **force re-cert** (reset completion, re-notify enrolled learners and their managers, re-base the certificate `expires_at`). This is the compliance behaviour a regulated LMS needs.

The **legislation example** becomes concrete: a change record with `category = legislative_update`, `classification = major`, referencing the legislation, forces a `2.0`, requires approver sign-off, and triggers re-certification notifications (via the notifications module) to everyone holding a certificate on the old version.

Supporting behaviours:

- **Assisted classification.** Default to author-declared, but a heuristic can *suggest* "major" when edits touch a large proportion of slides or any required/assessment content; the approver confirms. "Minor" claimed on heavy edits gets flagged for review — so classification can't be gamed to skip re-cert.
- **Audit.** Every change record is immutable and logged (who classified, why, what changed) — the same `work_item_log` / audit trail, improving on the source tool's "log everything" gap.
- **Tracker integration.** A change record can *be* a work item on the Course Production board (e.g. flowing *Review Required → Writing → Uploaded → Approved-Live*), so a legislation-driven rewrite runs through the same pipeline, review dates, and sign-off as any other production work — and the review-due cron (§9) is what surfaces "this course is due a legislative review" in the first place.

**Tables (sketch):** `change_records` — `course_id`, `from_version_id`, `to_version_id` (nullable until published), `classification` (minor|major), `category`, `reason`, `summary`, `learner_impact` (none | resume_ok | force_recert), `raised_by`, `approved_by`, `created_at`; optionally `change_impact` capturing the affected modules/slides for the heuristic and the reviewer's context.

---

## 14. Suggested phased delivery

1. **Engine + schema** — boards, stages, priorities, work_items (+ polymorphic subject), work_item_log, membership; RLS; seed the Course Production template with the 14 stages. (Fold in `005` per §12.)
2. **List view (tracker grid)** — the inline-editable data-table with stage/priority/date editing + saved views + ad-hoc filter, embedded in Course Management, scoped to courses.
3. **Kanban view** — the drag-to-transition board component.
4. **Automation engine + change management** — stage-entry rules + checklist gating + the review-due cron rule (config-driven), raising notification events; plus `change_records` (§13) with minor/major classification driving the `version_migration_policy` (in-place vs new major version + re-cert).
5. **Ideas → backlog → sprints** — the Client Ideas board, promotion flow, and sprint containers.
6. **Central Task module** — the top-level cross-board home + board switcher.
7. **Reporting + scheduling** — report builder + digest schedules via the notifications module.
8. **Archive management + purge**, then **Marketing pipeline** as a second application to prove reuse.
9. **Phase-2 backlog** — duplicate-title prompts, note tags, progress estimates, launch/update-planning fields, relative-date filter grammar, WhatsApp channel (notifications module).

---

## 15. Decisions to confirm

- **Generalise `005` (Option A) vs coexist (Option B)** — the pivotal one; recommend A.
- **Change classification** — author-declared with an approver confirm, plus a heuristic that suggests "major" past an edit-size threshold? And for compliance courses, should "major" default to finish-then-switch or force re-cert?
- **Central module first, or the embedded course tracker first?** (Recommend the embedded course tracker first — immediate value, proves the engine — then lift the central module over it.)
- **Board-role model** — is a simple viewer/contributor/manager per board enough, or do you need per-stage permissions (e.g. only approvers can move to *Approved*)?
- **Editorial vs production granularity** — keep the per-version editorial approval (`005`) *and* the course-level production tracker as two boards (recommended), or collapse to one?
- **Sprint scope** — sprints per board, or platform-wide cross-board sprints?

---

*Proposal only — nothing built. On your steer (especially the Option A/B call and which surface to build first), the natural first step is the engine + schema migration with the Course Production template, then the embedded tracker list view on the data-table you already have.*
