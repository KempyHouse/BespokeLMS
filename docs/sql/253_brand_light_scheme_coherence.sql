-- 253: the brand token family gets a coherent LIGHT half.
--
-- The brand-* tokens were authored for the dark marketing site, and only
-- color-brand-bg ever received a real light value. Any light-scheme page
-- built from them - the sign-in screen was the first - rendered a dark-site
-- surface (#111a22) floating on a white page with near-white ink.
--
-- Order matters: each token's current default IS today's dark rendering
-- (the public site pins data-theme='dark', whose resolution falls back to
-- the light default when dark_value is null). So the dark slot is frozen
-- FIRST, byte-for-byte, and only then does the light slot become light.
-- The marketing site does not change by one pixel.

update public.design_tokens
set dark_value = default_value
where key in ('color-brand-surface','color-brand-ink','color-brand-ink-soft','color-brand-ink-faint','color-brand-line')
  and dark_value is null;

update public.design_tokens set default_value = '#ffffff' where key = 'color-brand-surface';
update public.design_tokens set default_value = '#0b1620' where key = 'color-brand-ink';
update public.design_tokens set default_value = '#45566a' where key = 'color-brand-ink-soft';
update public.design_tokens set default_value = '#7b8a9a' where key = 'color-brand-ink-faint';
update public.design_tokens set default_value = '#dbe4ec' where key = 'color-brand-line';
