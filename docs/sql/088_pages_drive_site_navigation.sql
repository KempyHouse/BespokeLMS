-- 088: site navigation derives from the pages. APPLIED to pqmdtqsscyltykgcwwus.
--
-- Publish a page and it appears in the site header; unpublish it and it
-- leaves; sort_order is nav order. Navigation can therefore never point at a
-- page that does not exist - the failure a hand-maintained menu produces
-- eventually, every time.
--
-- show_in_nav covers the pages that must exist but not appear: a contact page
-- rendered as the header's call-to-action button, a campaign landing page, a
-- legal page that belongs in the footer. nav_label covers the page whose
-- title is right for the tab but too long for the header.
--
-- The header convention (see site/partials/header.blade.php): a published
-- page at /contact with show_in_nav = false becomes the header CTA button,
-- labelled by its nav_label. The wording of the button is content.

alter table public.web_pages
  add column if not exists show_in_nav boolean not null default true;

alter table public.web_pages
  add column if not exists nav_label text;
