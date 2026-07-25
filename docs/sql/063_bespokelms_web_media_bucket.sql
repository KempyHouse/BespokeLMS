-- 063: the media library's storage home.  APPLIED to pqmdtqsscyltykgcwwus.
--
-- Public bucket, because these are website images served to anonymous
-- visitors: a signed URL would expire in the middle of a cached page. Nothing
-- private ever belongs here.
--
-- There are deliberately NO storage policies. Every write goes through the
-- application with the service-role key, so the object path is decided by the
-- server and never by the browser. Reads are the public CDN path. This matches
-- the other public buckets (avatars, branding, course-covers), which also have
-- no policies for the same reason.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'web-media',
  'web-media',
  true,
  10485760,
  -- 063b removed image/svg+xml from this list. An SVG is a document that can
  -- carry script and would be served from our own origin; the application
  -- refuses it, and the bucket should agree so a direct API call cannot get
  -- one in either.
  array['image/png','image/jpeg','image/webp','image/gif']
)
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The object path must start with the owning organisation's id. The
-- application builds the path, so this is belt and braces: if a bug ever let a
-- caller choose the prefix, the row would be refused rather than silently
-- filed under another tenant.
alter table public.web_media
  drop constraint if exists web_media_path_prefix;

alter table public.web_media
  add constraint web_media_path_prefix
  check (path like organization_id::text || '/%');

-- Alt text is not optional. An image published without it is an accessibility
-- failure that no later review reliably catches, so the database refuses the
-- row. This is the third of three gates: the upload form, the writer, and here.
alter table public.web_media
  drop constraint if exists web_media_alt_text_present;

alter table public.web_media
  add constraint web_media_alt_text_present
  check (alt_text is not null and length(btrim(alt_text)) between 1 and 300);

create index if not exists web_media_org_created_idx
  on public.web_media (organization_id, created_at desc);

create index if not exists web_media_site_idx
  on public.web_media (site_id);
