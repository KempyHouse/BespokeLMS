-- =====================================================================
-- 007a_seed_territories.sql  —  optional starter vocabulary for the
-- `territories` table (migration 007). Safe to run once; re-running is a
-- no-op thanks to ON CONFLICT (code) DO NOTHING.
--
-- Structure: top-level regions as roots, nations/countries nested beneath
-- them via parent_id. Extend or replace freely — the availability editor
-- reads whatever is here, grouped by parent.
-- =====================================================================

-- Roots (regions). Stable codes so children can reference them.
insert into territories (code, name, sort) values
  ('UKI',  'United Kingdom & Ireland', 10),
  ('EU',   'Europe (rest of)',         20),
  ('NA',   'North America',            30),
  ('APAC', 'Asia-Pacific',             40),
  ('ROW',  'Rest of world',            90)
on conflict (code) do nothing;

-- UK & Ireland nations.
insert into territories (parent_id, code, name, sort)
select t.id, v.code, v.name, v.sort
from (values
  ('GB-ENG', 'England',           1),
  ('GB-SCT', 'Scotland',          2),
  ('GB-WLS', 'Wales',             3),
  ('GB-NIR', 'Northern Ireland',  4),
  ('IE',     'Ireland',           5)
) as v(code, name, sort)
cross join territories t
where t.code = 'UKI'
on conflict (code) do nothing;

-- North America.
insert into territories (parent_id, code, name, sort)
select t.id, v.code, v.name, v.sort
from (values
  ('US', 'United States', 1),
  ('CA', 'Canada',        2)
) as v(code, name, sort)
cross join territories t
where t.code = 'NA'
on conflict (code) do nothing;

-- Asia-Pacific.
insert into territories (parent_id, code, name, sort)
select t.id, v.code, v.name, v.sort
from (values
  ('AU', 'Australia',   1),
  ('NZ', 'New Zealand', 2)
) as v(code, name, sort)
cross join territories t
where t.code = 'APAC'
on conflict (code) do nothing;
