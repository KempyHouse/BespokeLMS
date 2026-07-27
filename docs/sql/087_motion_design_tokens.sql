-- 087: motion joins the design-token contract. APPLIED to pqmdtqsscyltykgcwwus.
--
-- The public-site motion layer reads these as CSS custom properties. They are
-- tokens rather than constants for the same reason colours are: a tenant's
-- site should be tunable without engineering, and "how the site moves" is as
-- much a brand decision as what colour it is. A luxury brand may want 900ms
-- and a long settle; a discount brand may want 250ms and snap.
--
-- themeable = true so brand kits can override them. The layout carries
-- identical fallbacks in var() defaults, so a site renders and animates
-- correctly even if the token pipeline returns nothing.

insert into public.design_tokens (key, css_var, type, default_value, themeable, category, label, helper, editor_group, sort_order)
values
  ('motion-duration-m', '--motion-m', 'duration', '450ms', true, 'motion',
   'Motion — standard', 'How long most animations run. Lower feels snappier, higher feels calmer.', 'Motion', 910),
  ('motion-duration-l', '--motion-l', 'duration', '700ms', true, 'motion',
   'Motion — long', 'Used for section reveals as a page is scrolled.', 'Motion', 920),
  ('motion-ease', '--motion-ease', 'easing', 'cubic-bezier(0.22, 1, 0.36, 1)', true, 'motion',
   'Motion — easing', 'The curve animations follow. The default starts fast and settles gently.', 'Motion', 930),
  ('motion-rise', '--motion-rise', 'dimension', '24px', true, 'motion',
   'Motion — travel', 'How far content rises as it appears. 0px keeps fades only.', 'Motion', 940)
on conflict (key) do nothing;
