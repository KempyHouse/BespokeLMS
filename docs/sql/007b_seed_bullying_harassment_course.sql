-- =====================================================================
-- 007b_seed_bullying_harassment_course.sql
--
-- Seeds ONE course — "Bullying and Harassment Awareness" — with its full
-- editorial record, sourced from the Food Compliance HQ course editor
-- (course 36). Maps onto the BespokeLMS schema from migrations 001–007:
--   courses, course_versions, course_pricing, course_territories,
--   course_authors, course_categories (link), tags + course_tags.
--
-- Idempotent: safe to run more than once. The course is keyed by slug; all
-- child rows are guarded by NOT EXISTS / ON CONFLICT.
--
-- Prerequisites: migrations 001–007 applied. (007a territories optional —
-- this file inserts its own 'United Kingdom' territory if absent.)
--
-- Mapping notes:
--   * FCHQ "Between lessons"            -> assessment_placement = inline_between_modules
--   * FCHQ CPD 60 mins                  -> duration_min = 60, cpd_points = 1 (1 hr)
--   * FCHQ Price £3.99 / Credit 1       -> pricing_type one_off, 399p, credit_cost 1
--   * FCHQ "Unlimited retakes"          -> assessment_retry_limit = -1
--   * FCHQ certificate "Not Applicable" -> certificate_validity NULL (never expires)
--   * FCHQ category                     -> existing "Workplace, Compliance & HR"
--   * catalog_status set to 'published' (source was a complete, non-coming-soon course)
-- =====================================================================

do $body$
declare
  v_course_id  uuid;
  v_version_id uuid;
  v_cat_id     uuid;
  v_terr_id    uuid;
begin
  -- ---- category (reuse the closest existing global category) -------------
  select id into v_cat_id from course_categories
   where name = 'Workplace, Compliance & HR' limit 1;

  -- ---- course (identity + editor fields) --------------------------------
  select id into v_course_id from courses
   where slug = 'bullying-and-harassment-awareness' limit 1;

  if v_course_id is null then
    insert into courses (
      title, slug, content_type, catalog_status, category_id,
      level, duration_min, price_pennies, credits, description,
      hero_image_alt, cpd_points, cpd_body,
      meta_title, meta_description, meta_keywords,
      issues_certificate, certificate_validity, auto_reassign_on_expiry
    ) values (
      'Bullying and Harassment Awareness',
      'bullying-and-harassment-awareness',
      'native',
      'published',
      v_cat_id,
      'Awareness',
      60,
      399,
      1,
      $q$This training course offers a clear and practical guide to understanding, recognising, and addressing bullying and harassment within the hospitality industry. It explores how harmful behaviours can appear in kitchens, cafes, restaurants, hotels, and catering environments, and how to respond to them.$q$,
      'Two teenagers intimidating another student against a brick wall, illustrating the concept of bullying and the need for awareness and prevention.',
      1,
      'CPD Certified (60 minutes)',
      'Bullying & Harassment Awareness for Hospitality | FCHQ',
      $q$Empower food industry professionals to maintain high standards of safety and compliance with Food Compliance HQ's comprehensive CPD course. Learn essential practices to create safe and hygienic environments for all.$q$,
      'bullying awareness, harassment training, workplace respect, hospitality training, catering staff, inclusive workplace, anti-bullying course, harassment prevention, equality and diversity',
      true,
      null,
      false
    )
    returning id into v_course_id;
  end if;

  -- ---- version 1 (versioned descriptive copy + assessment) --------------
  select id into v_version_id from course_versions
   where course_id = v_course_id and version_no = 1 limit 1;

  if v_version_id is null then
    insert into course_versions (
      course_id, version_no, semver, status,
      assessment_placement, pass_mark_pct,
      description, description_short,
      aims, aims_short,
      objectives, objectives_short,
      review_interval, published_at
    ) values (
      v_course_id, 1, '1.0.0', 'published',
      'inline_between_modules', 80,
      $q$<p>This training course offers a clear and practical guide to understanding, recognising, and addressing bullying and harassment within the hospitality industry.</p>
<p>You will explore how harmful behaviours can appear in kitchens, cafes, restaurants, hotels, and catering environments &mdash; often emerging under pressure or being dismissed as &ldquo;just banter.&rdquo;</p>
<p>Through this course, you will learn to:</p>
<ul>
<li>Identify early signs of bullying and harassment.</li>
<li>Understand the serious impacts these behaviours have on individuals, team morale, and business reputation.</li>
<li>Navigate the legal responsibilities of employers, managers, and employees.</li>
<li>Confidently report and respond to concerns when they arise.</li>
</ul>
<p>The training also highlights the importance of fostering safe, respectful, and inclusive workplaces, making it essential for everyone in the food and hospitality sector, from frontline staff to senior leaders.</p>$q$,
      $q$Learn to recognise, prevent, and respond to bullying and harassment in hospitality settings. This course covers early warning signs, legal duties, and reporting, helping create safer, more respectful workplaces for all.$q$,
      $q$<p>To equip hospitality and catering professionals with the knowledge, awareness, and practical tools to recognise, prevent, and respond to bullying and harassment in the workplace, creating safer, more respectful, and inclusive working environments.</p>$q$,
      $q$To equip hospitality and catering professionals with the skills to recognise, prevent, and respond to workplace bullying and harassment, fostering safer, more respectful, and inclusive working environments.$q$,
      $q$<p>By the end of this course, learners will be able to:</p>
<ul>
<li>Define what constitutes bullying and harassment in a workplace context.</li>
<li>Distinguish between direct and indirect behaviours and identify different types of bullying and harassment.</li>
<li>Understand the legal rights and responsibilities of both employers and employees.</li>
<li>Recognise who may be more vulnerable to bullying and harassment, and why.</li>
<li>Describe the emotional, psychological, and professional impact these behaviours can have on individuals and teams.</li>
<li>Identify the warning signs and patterns of bullying and harassment.</li>
<li>Respond appropriately if they or a colleague is being bullied or harassed.</li>
<li>Understand how to report concerns formally and informally.</li>
<li>Learn how leadership, team culture, and workplace practices can prevent bullying and harassment.</li>
</ul>$q$,
      $q$By the end of this course, learners will be able to recognise, prevent, and respond to bullying and harassment, understand legal duties, identify vulnerable individuals, and foster a respectful, supportive workplace culture.$q$,
      interval '12 months',
      now()
    )
    returning id into v_version_id;
  end if;

  -- point the course at its published version
  update courses
     set current_published_version_id = v_version_id
   where id = v_course_id
     and current_published_version_id is distinct from v_version_id;

  -- ---- pricing (£3.99 one-off; 1 credit; unlimited assessment attempts) --
  insert into course_pricing (
    course_id, pricing_type, price_pennies, currency, credit_cost,
    assessment_retry_limit
  ) values (
    v_course_id, 'one_off', 399, 'GBP', 1, -1
  )
  on conflict (course_id) do update set
    pricing_type           = excluded.pricing_type,
    price_pennies          = excluded.price_pennies,
    currency               = excluded.currency,
    credit_cost            = excluded.credit_cost,
    assessment_retry_limit = excluded.assessment_retry_limit;

  -- ---- territory (United Kingdom) ---------------------------------------
  insert into territories (code, name, sort)
  values ('GB', 'United Kingdom', 0)
  on conflict (code) do nothing;

  select id into v_terr_id from territories where code = 'GB' limit 1;

  if v_terr_id is not null then
    insert into course_territories (course_id, territory_id)
    values (v_course_id, v_terr_id)
    on conflict (course_id, territory_id) do nothing;
  end if;

  -- ---- author -----------------------------------------------------------
  if not exists (
    select 1 from course_authors
     where course_id = v_course_id and display_name = 'Food Compliance HQ'
  ) then
    insert into course_authors (course_id, display_name, credit_label, sort)
    values (v_course_id, 'Food Compliance HQ', 'Author', 0);
  end if;

  -- ---- tags: FCHQ taxonomies preserved as global tags -------------------
  insert into tags (key, label, sort)
  select key, label, sort from (values
    -- Learning outcomes
    ('lo-legal-regulatory-standards',   'Understand Relevant Legal and Regulatory Standards', 0),
    ('lo-safeguarding-practices',       'Safeguarding Practices',                             1),
    ('lo-identify-monitor-document-ccps','Identify, Monitor & Document CCPs',                 2),
    -- Legislation
    ('leg-equality-act-2010',           'Equality Act 2010',                                  10),
    ('leg-health-safety-at-work-act',   'Health and Safety at Work Act',                      11),
    ('leg-protection-from-harassment-act-1997', 'Protection from Harassment Act 1997',        12),
    -- Sector
    ('sector-restaurant-cafe-canteen',  'Restaurant/Cafe/Canteen',                            20),
    ('sector-hotel-bb-guesthouse',      'Hotel/Bed & Breakfast/Guest House',                  21),
    ('sector-other-catering-premises',  'Other Catering Premises',                            22),
    ('sector-pub-bar-nightclub',        'Pub/Bar/Nightclub',                                  23),
    ('sector-takeaway-sandwich-shop',   'Takeaway/Sandwich Shop',                             24),
    ('sector-hospitals-childcare-caring','Hospitals/Childcare/Caring Premises',               25),
    ('sector-retailers-supermarkets',   'Retailers - Supermarkets/Hypermarkets',              26),
    ('sector-school-college-university', 'School/College/University',                         27),
    -- Client roles & responsibilities
    ('role-chefs',                      'Chefs (Head, Sous, Commis)',                         30),
    ('role-front-of-house-food',        'Front-of-House Staff Handling Food',                 31),
    ('role-kitchen-assistant',          'Kitchen Assistant',                                  32),
    ('role-mobile-catering-staff',      'Mobile Catering Staff',                              33),
    ('role-care-worker-food',           'Care Worker Handling Food',                          34),
    ('role-food-handler',               'Food Handler',                                       35),
    ('role-catering-supervisor',        'Catering Supervisor',                                36),
    -- Related organisations & charities
    ('org-acas',                        'ACAS (Advisory, Conciliation and Arbitration Service)', 40),
    ('org-citizens-advice',             'Citizens Advice Bureau',                             41)
  ) as v(key, label, sort)
  on conflict (key) do nothing;

  insert into course_tags (course_id, tag_id)
  select v_course_id, t.id
    from tags t
   where t.key in (
     'lo-legal-regulatory-standards','lo-safeguarding-practices','lo-identify-monitor-document-ccps',
     'leg-equality-act-2010','leg-health-safety-at-work-act','leg-protection-from-harassment-act-1997',
     'sector-restaurant-cafe-canteen','sector-hotel-bb-guesthouse','sector-other-catering-premises',
     'sector-pub-bar-nightclub','sector-takeaway-sandwich-shop','sector-hospitals-childcare-caring',
     'sector-retailers-supermarkets','sector-school-college-university',
     'role-chefs','role-front-of-house-food','role-kitchen-assistant','role-mobile-catering-staff',
     'role-care-worker-food','role-food-handler','role-catering-supervisor',
     'org-acas','org-citizens-advice'
   )
     and not exists (
       select 1 from course_tags ct
        where ct.course_id = v_course_id and ct.tag_id = t.id
     );

  raise notice 'Seeded course % (version %)', v_course_id, v_version_id;
end
$body$;
