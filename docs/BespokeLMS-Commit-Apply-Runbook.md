# BespokeLMS — commit & apply runbook (clean baseline)

**As of 23 July 2026.** The earlier multi-agent tangle already resolved: commit `6064ba5` committed + pushed my course workspace, the Global Courses nav-regression fix, and the AI agent's Email module together — all live. The learners-view agent has pushed their Course Library work since (`57c9366`, `7e80ac1`). So this is now light.

## Current state

- **App repo** (`bespokelms-app`) — level with origin. Uncommitted, small: my **footer removal** in `layouts/app.blade.php` (the PROTOTYPE-REFERENCE / MY-old / TEAM-old block) + a couple of 1-line `platform/courses/*` tweaks + the **learners-view agent's in-progress** work (`CourseLibraryController`, `my/courses/*`, `my-nav`, `workspace-switcher`, `app.css`). Only `_to_delete/` should be left out.
- **Docs repo** (`BespokeLMS`) — migrations `009`, `010`, `011` + `Learner-Data-Contract.md` + `Schema-Map.html` not yet committed.
- **Supabase** — migrations `003`–`011` validated, not yet applied.

## Step 1 — App repo: commit the current round

The bulk of the uncommitted set is the **learners-view agent's active build**, so agree a moment with them when their My-courses work is at a stopping point (nothing mid-write). Then:

```powershell
cd C:\Claude\bespokelms-app
Remove-Item .git\*.lock -Force -ErrorAction SilentlyContinue
git status                         # review — courses footer + learner course-library changes
git add -A
git reset -- _to_delete/           # keep the junk folder out of the commit
git commit -m "Remove prototype footer; learner Course Library build"
git push
```

Then have **both other agents `git pull`** in `C:\Claude\bespokelms-app` before their next edit — this resync is what stops the revert/clobber cycle.

## Step 2 — Docs repo: migrations 009–011 + docs

```powershell
cd C:\Claude\BespokeLMS
Remove-Item .git\*.lock -Force -ErrorAction SilentlyContinue
git add docs/
git commit -m "Migrations 009-011 + learner data contract + schema map"
git push
```

Docs-only — no effect on the Netlify prototype.

## Step 3 — Apply migrations in Supabase (SQL Editor)

Run **in order, one at a time**, checking each succeeds before the next (`001`/`002` already live):

```
003 → 004 → 005 → 006 → 007 → 008 → 009 → 010 → 011
```

Each was validated by applying the whole chain on Postgres 16, so they apply cleanly in sequence. After `003` the catalogue's Type/Version/Visibility columns populate; `007` adds pricing/cert; `008` seeds the Course Production tracker (28 courses backfilled as cards); etc.

## Step 4 — Verify

- **Laravel Cloud** — the Step-1 push triggers a deploy; watch it go green.
- **Footer** — gone from every page.
- **Global Courses** — the rail link opens `/platform/courses` (already fixed and live from `6064ba5`).
- **Catalogue** — after migrations, `/platform/courses` shows real Type / Version / Visibility instead of the pre-migration fallback.
- **Requires** `SUPABASE_SERVICE_ROLE_KEY` in the Laravel Cloud env (already set — the Tenants and Courses consoles use it).

## Guardrail — stop the recurring clobber

The reverts kept happening because three agents edit the same `home.blade.php` nav block + `routes/web.php`. Two cheap fixes:

1. **Commit + push shared-file changes promptly** (small commits), and **`git pull` before editing a shared file**. The clobbering only bit because hours of uncommitted work accumulated in the same files.
2. **Drive the platform rail from a config array** — one entry per feature — so adding a nav item touches a data file, not the same `<a>` block every agent reaches for. I can implement this once the baseline is in; it removes the whole class of nav regressions.

## After this

Clean baseline + live schema unblocks the app layer. Next builds (my lane): the **course editor form** (wires the `007` fields), the **Kanban/tracker UI** over the `008` engine, the **automation-execution service** (StageEntered → stamp/assign/branch/notify via the notifications module), and wiring the **course workspace tabs** to real data. All best built against live tables, coordinated so shared files don't collide.
