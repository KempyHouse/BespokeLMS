# Managed App Header — Implementation Plan

**Goal:** the main header (top bar) becomes a managed menu in CMS Builder → Navigation Menus, alongside My workspace rail, Outbound sub-rail, etc. — so its order, visibility, labels and the account dropdown's contents are editable, versioned, publishable and rollback-able without engineering.

**Status:** plan only — nothing built. Research date 2026-07-24, against the live schema and `layouts/app.blade.php`.

---

## A. What the header contains today (inventory)

From `resources/views/layouts/app.blade.php` (lines 36–178), left to right:

| # | Element | Nature | Manageable? |
|---|---------|--------|-------------|
| 1 | Brand / logo → `dashboard` | **Widget** — logo comes from the active brand kit | Slot managed (`header.brand`); artwork managed in Branding kits (see §B2) |
| 2 | Search box (GET → `platform.home`, `q`) | Functional **widget** (form) | Slot only — position/visibility managed; internals code-owned |
| 3 | Quick actions ⚡ dropdown | Widget — items composed per-role in `AppServiceProvider` (`$quickActions`) | Slot only in v1; per-action management is a later phase |
| 4 | Help chat 💬 (`toggleChat()`) | Client **action** — already modelled by registry `my.help` / `openChat` | **Yes** — fully manageable today |
| 5 | Notifications 🔔 + badge (`toggleNotifications()`) | Widget (badge count is live data) | Slot only |
| 6 | Account menu (avatar + name → dropdown) | **Group** of real links + placeholders + widgets | **Yes — the main win** |

Account dropdown contents: identity block (widget), **Preferences** group — Personal preferences (`profile.edit#preferences`, live), Notification settings (*Soon*, hard-coded); **Account** group — My profile (`profile.edit`, live), Security & password (*Soon*, hard-coded), Home (`dashboard`, live); signed-in status line (widget); Log out (**POST form + CSRF** — must never become a plain link).

Those hard-coded *Soon* rows are exactly what the registry's `planned`/`coming_soon` statuses model — under management they become real placeholders that obey the owner-only + "Show upcoming" rules automatically.

## B. Data model changes (migration 020)

Current enums (verified live): `nav_menu_type = {switcher, rail, sub_rail, page_tabs}` · `nav_item_type = {group, link}` · `nav_route_type = {page, anchor, external, section, action}`.

1. `ALTER TYPE nav_menu_type ADD VALUE 'header'` — PG requires enum additions committed before first use, so 020a (enum) and 020b (seed) are separate migrations.
2. `ALTER TYPE nav_route_type ADD VALUE 'widget'` — a render slot the app fills (search, notifications, quick actions, identity, logout). Widgets have no href; the component maps `widget key → partial`. Unknown widget keys render nothing (same drop-don't-break rule as missing routes).
3. New menu row: `nav_menus` key **`app-header`**, `menu_type 'header'`, `domain 'shared'`, global (`organization_id NULL`).
4. Seed published v1 mirroring today's header exactly:
   - Flat items (order 10…): `header.brand` (widget — see §B2) · `header.search` (widget) · `header.quick_actions` (widget) · `my.help` (action `openChat` — reuses the existing registry entry) · `header.notifications` (widget)
   - Group **Account** with children (depth 2 — fits the existing `depth ≤ 2` constraint): `account.identity` (widget) · `account.preferences` (anchor `profile.edit#preferences`, live) · `account.notification_settings` (coming_soon) · `account.profile` (page `profile.edit`, live) · `account.security` (coming_soon) · `account.home` (page `dashboard`, live) · `account.logout` (widget — POST form partial)
   - Role grants: all five roles on every live item (today's header is role-agnostic).

## B2. Brand slot: tenant logo & favicon via Branding kits

The header's brand position becomes a managed **`header.brand` widget slot** (first flat item in the seed) rather than fixed markup. What it *renders* comes from the branding system, not the menu:

- **Schema already ready:** `brand_kits` has `logo_path` and `favicon_path` columns today (verified live) — currently unused. No new tables; BespokeLMS's own identity is the platform-level kit (`organization_id NULL`), each tenant's is their kit (`is_default` marks the active one).
- **Widget behaviour:** in a tenant context the slot renders the tenant's active kit logo linking to that workspace's home; otherwise the BespokeLMS platform kit logo. Missing `logo_path` → the current wordmark ("B" mark + Bespoke**LMS**) renders as the fallback, so the header never loses its identity.
- **Favicon (companion change, not a menu item):** `layouts/app.blade.php` `<head>` emits `<link rel="icon">` from the same active kit's `favicon_path`, platform kit as fallback — favicons follow the tenant automatically.
- **Branding kit editors gain upload fields:** the tenant console's *Branding & brand kit* panel and the platform's own branding settings get logo + favicon upload (Supabase Storage bucket, path stored in the existing columns; sudo-gated like the rest of `updateBranding`, audited). Constraints: SVG/PNG, small size caps, served via public storage URL.
- **Division of duties:** Navigation Menus controls *where the brand slot sits and who sees it*; Branding kits control *what artwork it shows*. Same separation as every other widget slot.

## C. Registry additions (code-first, then `nav:sync-registry`)

Add to `app/Support/Navigation/RouteRegistry.php` (source of truth): the 10 new keys above (including `header.brand`) — widgets as `route_type 'widget'`, scope `shared`, sensible `default_label`/`default_icon`; the two placeholders as `coming_soon`. The existing sync command upserts them; nothing manual in SQL.

## D. Resolver changes (`NavigationResolver`)

- New `headerItems(string $menuKey = 'app-header'): ?array` — same layered visibility pipeline, returns ordered slots: `{kind: widget|action|link|group, key, label, icon, href?, action?, soon, children?}`. Groups keep their filtered children (the account dropdown).
- `presentItem()` learns `route_type 'widget'` → no href, `kind 'widget'` (skips the `Route::has()` guard).
- `flush()` adds `app-header` to the menu list; cache key pattern unchanged.
- **Fail-safe unchanged:** any failure returns `null` → the component renders the current hard-coded header verbatim. The header can never vanish — it's on every page including My/Team.

## E. Component changes

Extract the header block from `layouts/app.blade.php` into `components/app-header.blade.php`:

- Resolver-driven loop over `headerItems()`; widget slots dispatch to small code-owned partials (`header/search`, `header/quick-actions`, `header/notifications`, `header/identity`, `header/logout`) — a `@switch` on widget key, **not** `<x-dynamic-component>` with array props (house lesson).
- Action items render the icon-button wired to the whitelisted client action (`ALLOWED_ACTIONS` already covers `openChat`; extend only if new actions are added later).
- Account group renders as today's dropdown; live children as links, placeholders with the Soon pill (owner-only + "Show upcoming").
- The brand slot renders via a `header/brand` partial reading the active brand kit (§B2); responsive layout, sticky/backdrop classes stay fixed in the component. Fallback: today's markup, verbatim.
- Layout passes `$user` through (existing `$hdrUser` pattern retained).

## F. Builder impact (mostly free)

- `app-header` appears in the Navigation Menus index automatically (menus() lists all rows) — list and grid views included.
- Editor: registry picker gains the new keys; widget items get a small "Widget — rendered by the app" badge and no label-override confusion; group editing, drag-and-drop, role checkboxes, draft/publish/rollback, sudo gate, audit — all inherited unchanged.
- Preview-by-role: widgets render as neutral chips; links/placeholders as now.

## G. Risks & decisions to confirm

1. **Logout stays a POST form** — modelled as a widget precisely so it can't be edited into a GET link (CSRF + safe-method correctness).
2. **Search target** is workspace-agnostic today (`platform.home?q=`) — widget internals stay code-owned, so improving that later doesn't touch the menu model.
3. **Quick actions** remain a single slot in v1; managing individual quick actions (per-role, per-tenant) is a natural phase 2 with the same pattern.
4. **Tenant-branded headers** (per-tenant `organization_id` variants) come free with the menu-duplication backlog item — the schema already allows it.
5. Enum `ADD VALUE` needs the two-step migration noted above.
6. New Blade in the header path is high-blast-radius: deploy behind the same `nav_data_driven` flag discipline — flag off → hard-coded header everywhere.

## H. Build order (when approved)

1. Migration 020a (two enum values) → 020b (registry rows + `app-header` menu + seeded published v1).
2. `RouteRegistry.php` entries + run `nav:sync-registry` (verifies parity).
3. Resolver: `headerItems()` + widget handling + flush list.
4. `components/app-header.blade.php` + layout swap + widget partials (brand partial reads the active brand kit with wordmark fallback).
5. Branding kits: logo/favicon upload fields (platform + tenant editors, Supabase Storage, sudo + audit) and favicon emission in the layout head.
6. Builder polish (widget badge in editor + preview chips).
7. Verify live: header identical pre/post on all three workspaces; then prove management by reordering an icon and publishing, and prove branding by setting a tenant logo.

Estimated at one-to-two working sessions now that branding uploads are in scope (step 5 is the addition).
