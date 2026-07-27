# BespokeLMS marketing website — research and implementation plan

**Status:** Proposal for Andrew's sign-off. Nothing in this document has been written
into the CMS. Copy goes into the page builder only after approval, because the copy
below is a draft of our public voice, not content to be quietly seeded.

**What this covers:** the competitor landscape we are selling against, the positioning
that follows from it, a full site map, section-by-section build plans for every page
with draft copy mapped to the 19 blocks the CMS actually has, an imagery system, a
motion and animation specification (one engineering slice is needed — the renderer
has no motion layer today), and a build order.

**The standing constraints this plan honours:**

- Consultation-led. There is no self-serve sign-up anywhere on this site, and that
  absence is treated as a positioning asset, not a missing feature.
- No dummy data. Every statistic, logo, quote, name and photograph in the copy below
  is either real or explicitly marked as needing a real value from Andrew before the
  section can be built.
- Competitors are researched here but never named on the public site.
- The site is built with BespokeLMS's own CMS. That is not a constraint — it is the
  single best proof point we have, and the copy uses it.

---

## 1. The market we are selling against

Three different kinds of company will be compared against us, depending on who the
prospect is. Each has a distinct marketing playbook, and each leaves a gap.

### Arena 1 — white-label LMS platforms

The platforms a reseller prospect will have already Googled: Thinkific Plus,
LearnWorlds, Kajabi, TalentLMS, iSpring Learn, Docebo, Absorb, Blend-ed.

What their marketing emphasises: branding depth, e-commerce, branded mobile apps,
AI authoring, per-user pricing tiers.

Where they are weak, consistently:

- **White-label is a paywall, not an architecture.** LearnWorlds gates full
  white-label behind its ~$249/month tier and charges another ~$149/month for a
  branded app. Kajabi's footer branding and app branding are gated. Thinkific's
  full white-label needs the custom-priced Plus tier. The pattern across the
  category: your brand is an upsell.
- **Per-user pricing punishes growth.** TalentLMS and iSpring price per registered
  or active user, so a reseller's cost scales with their success.
- **Self-serve means alone.** The model is sign up, watch the videos, build it
  yourself. Configuration help is a professional-services invoice.
- **The commercial stack is someone else's problem.** None of them ship a real CRM,
  none ship a consent management platform, and the "website" is a storefront
  template, not a page builder a marketing team would choose to use.

### Arena 2 — hospitality and food-sector learning platforms

The sector incumbents a Turner Price or March Foods prospect will know: Flow
Learning by MAPAL (which absorbed CPL Learning), Upskill People, and the
food-safety course libraries.

Their pitch is content depth and sector fit: ready-made hospitality compliance
modules, onboarding pathways, brand-standards training. Their weakness for our
prospect is the inverse of their strength: they sell *their* content under *their*
platform. A wholesaler who wants to sell training to its own customer base, under
its own name, with its own catalogue, is not their customer — it is their
competitor, and the platform is built accordingly.

### Arena 3 — training management systems

For prospects running commercial training as a business: Arlo and accessplanit
dominate UK search. Their marketing voice is energetic and admin-focused ("save
hours of admin", "crush sales targets"), and their substance is scheduling,
booking, and course administration. Both are demo-led rather than self-serve, so
the consultation model will not feel alien to prospects who have shopped here.

Their gap: they manage the training operation but not the learning itself in any
depth, the client-facing web presence is a bolt-on, and neither touches consent or
marketing compliance at all.

### The gap BespokeLMS occupies

Nobody in any of the three arenas offers this combination:

1. White-label as the architecture, not a pricing tier. Every tenant's domain,
   sign-in screen, certificates, and sender identity are theirs from day one.
2. The whole commercial stack in one platform: LMS, client-organisation
   management, reporting, a genuine CMS with a page builder, a sales CRM with
   marketing permissions, and a consent management engine — the pieces every
   training business otherwise buys from four vendors and stitches together.
3. A consultative delivery model. We configure the platform with the client
   through an onboarding partnership, and the roadmap is shaped by tenants rather
   than by a feature-vote forum.
4. Sector credibility in food and hospitality compliance, where the buying
   criteria are audit evidence and refresher discipline, not gamification.

Every page of the site exists to make one of those four points land.

---

## 2. Positioning and message architecture

### The one-line positioning

> BespokeLMS is the white-label learning platform delivered as a partnership:
> your courses, your clients, your website and your compliance evidence, all
> under your brand, configured with you rather than sold to you.

### The three audiences

**Resellers** (Turner Price, March Foods — companies with expertise and an
audience, who want to sell training under their own name). Their fear is looking
like they rent someone else's software. Their economics break on per-learner
pricing. Their buyers increasingly audit suppliers, so compliance posture is a
sales asset. Lead message: *a course business under your own name.*

**In-house operators** (companies training their own staff across sites and
shifts). Their pain is proof: audits, refresher cycles, role matrices, branch
reporting. Lead message: *every site, every shift, trained and provable.*

**Partners** (platforms like S4labour whose hospitality customers need training
their platform does not provide). Lead message: *your customers need this; it can
carry your recommendation without competing with you.*

The product-development module is deliberately absent from all public messaging —
it is our internal tooling, not a tenant selling point.

### What the site never does

- No public pricing grid. Pricing follows scope; the How we work page says so
  plainly and explains why.
- No "start free trial" or sign-up path. The only conversion action anywhere is a
  conversation.
- No competitor names, no comparison tables.
- No invented numbers, logos, or testimonials. Sections that need them stay
  unpublished until the real thing exists.

### Voice

UK English. Short declarative sentences. Concrete nouns over category words.
Confident enough to say "we do not do that" where true. The register to aim for:
a technical founder explaining their product to a smart operations director,
not a growth team addressing "businesses like yours". Sentence-case headings
everywhere. Every claim on the site must be one we can demonstrate in the
platform during the first consultation call.

---

## 3. Site map

```
/                      Home — the whole argument in one scroll
/platform              What the platform is, shown not listed
/sell-training         For resellers
/train-your-people     For in-house operators
/how-we-work           The consultation model (replaces "Pricing")
/partners              For platform partners
/about                 Already scaffolded: hero > rich-text > values-grid > team-grid > cta
/insights              Already scaffolded: hero > featured-post > post-grid > cta
/contact               The conversation starts here
/privacy  /cookies     Legal — with our own consent banner live on the site
```

Primary navigation: Platform · Who it's for (dropdown: Sell training / Train your
people / Partners) · How we work · Insights · About, with "Book a consultation" as
the persistent right-aligned button. Footer carries the legal pages, the
consent-preferences link (`#bl-consent` — our own runtime provides the preference
centre), and the line "This site runs on BespokeLMS."

---

## 4. Page-by-page build plan

Every section below names the CMS block it uses (all nineteen exist and are synced
to production), gives draft copy at prop level, an imagery direction, and a motion
spec keyed to the system in section 6. Copy lengths respect the block schemas.

### 4.1 Home

The page makes the whole argument in one scroll: what it is, why the brand depth
matters, what nobody else ships, how buying works. Aim for seven sections — Apple's
product pages earn length through pacing, and each section here is one idea.

**Section 1 — `hero`**

- Eyebrow: `The white-label learning platform`
- Heading: `Training software that carries your name`
- Body: `BespokeLMS runs your courses, your client accounts and your website under
  your own brand. Configured with you in a consultation, not sold to you from a
  pricing page.`
- Primary: `Book a consultation` → /contact
- Secondary: `See the platform` → /platform

Imagery: no photograph. A slow-moving generated gradient field in the brand
palette behind large type, with a tenant-branded product frame rising into view
below the fold line. The restraint is the statement.

Motion: headline and body rise 24px and fade in on load, staggered 80ms; gradient
pans over 30s on a loop; product frame parallaxes upward slightly on scroll (M2,
M4 in the motion spec). Reduced motion: everything static, gradient frozen.

**Section 2 — `logo-strip`**

Real client logos only, with written permission: Turner Price and March Foods once
signed. Until at least three logos exist this section stays hidden — a strip of
two reads as two. Label: `Working with`. PNG or WebP files (the media bucket
refuses SVG by design; export at 2x).

Motion: none, or the slow marquee (M5) once five or more logos exist. A static row
of three is stronger than three logos on a conveyor belt.

**Section 3 — `problem-solution`**

- Heading: `Most platforms make you choose`
- Problem: `Their badge on your training. Per-learner prices that rise with your
  success. A storefront template instead of a website. A CRM somewhere else, a
  cookie banner from a fourth vendor, and an integration project to hold it all
  together.`
- Solution: `One platform, delivered as yours. Courses, client organisations,
  reporting, a full marketing site and a consent engine, under your domain and
  your brand from the first day.`

Imagery: none. Two columns of type. Let the copy carry it.

Motion: the two panels reveal in sequence, problem first, solution 150ms behind
(M1 staggered) — the delay is the rhetoric.

**Section 4 — four `feature-showcase` sections, alternating sides**

This is the Apple-style scroll story: full-width sections, one idea each, product
frame on one side, short copy on the other.

*Showcase A — brand depth*
- Heading: `Your brand, everywhere it matters`
- Body: `Your domain. Your sign-in screen. Certificates issued in your name and
  emails sent from your own address. Learners and clients see one company:
  yours.`
- Imagery: the tenant sign-in screen and a certificate, both carrying a real
  tenant brand (Turner Price with permission, or the TeachHQ brand), framed in
  minimal browser chrome.

*Showcase B — client operations*
- Heading: `Every client in their own world`
- Body: `Organisations, branches, roles and visibility scoping. Sell to a company
  and their training stays theirs: their people, their reporting, their view.`
- Imagery: the organisation tree and a scoped dashboard, lightly annotated.

*Showcase C — evidence*
- Heading: `Proof, not promises`
- Body: `Completion records, CPD points and refresher cycles you can put in front
  of an auditor. Reporting that answers the question before it is asked.`
- Imagery: a reporting dashboard with real (anonymised) shapes, plus an exported
  evidence document.

*Showcase D — the commercial stack*
- Heading: `The parts nobody else ships`
- Body: `A page builder your marketing team will actually use. A sales CRM with
  marketing permissions built to UK rules. A consent engine that blocks trackers
  until visitors agree. You are looking at all three: this website runs on them.`
- Imagery: the page builder editing this very homepage — the most honest product
  shot available to us.

Motion: each showcase's media frame parallaxes gently (M4); copy reveals as it
enters (M1). No pinned scroll-jacking sections — they read as impressive and test
as infuriating.

**Section 5 — `stat-row`**

Real figures required from Andrew before this section is built. The shape:
courses delivered / learners trained / client organisations / years in
compliance training. If honest numbers are not yet compelling, hold the section —
a small true number beats a large vague one, but no number beats a padded one.

Motion: count-up on first view (M3). Numbers are server-rendered at their final
value; JS only animates from zero, so reduced-motion and no-JS visitors see the
truth immediately.

**Section 6 — `faq`**

Five questions, answered in the site's plain voice:

1. `Is this off-the-shelf or bespoke?` — `Both, honestly. The platform is built
   and running; the configuration is bespoke. You are not paying us to write
   software from scratch, and you are not bending your business around a
   template either.`
2. `Why is there no pricing page?` — `Because the price depends on scope, and
   pretending otherwise produces either padded tiers or surprise invoices. We
   would rather have one straight conversation.`
3. `Can we sell courses to our own clients?` — `Yes. That is the point. Client
   organisations, their learners and their reporting all live under your brand.`
4. `Who owns the data?` — `You own your data and your clients' data. Export is a
   feature, not a negotiation.`
5. `What does onboarding look like?` — `A consultation, then we configure the
   platform with you: brand, structure, catalogue, domains. You launch with it
   working, not with a login and a help centre.`

Motion: none beyond the standard reveal. Accordions animate height with the M1
easing.

**Section 7 — `cta`**

- Heading: `Tell us what you are trying to build`
- Body: `A conversation first. We will map the platform against what you need and
  be straight with you about fit.`
- Button: `Book a consultation` → /contact

Motion: none. The stillness after a long scroll is deliberate.

### 4.2 /platform

Structure: `hero` → `feature-grid` (the map) → three `feature-showcase` deep-dives
→ `image` (full architecture view) → `faq` (technical) → `cta`.

- Hero heading: `One platform, five jobs`
- Hero body: `Learning, client management, reporting, marketing and compliance
  usually mean five suppliers. BespokeLMS was built so they are one system that
  agrees with itself.`

`feature-grid` (six cards, each one sentence, no icon soup):
1. `Courses and CPD` — `Authoring, versioning, refresher cycles and CPD points.`
2. `Client organisations` — `Companies, branches, roles and scoped visibility.`
3. `Reporting` — `Evidence an auditor accepts and a client renews on.`
4. `Website builder` — `Nineteen content blocks, drafts, publishing and rollback.`
5. `Sales CRM` — `Contacts, deals, campaigns and marketing permissions with the
   lawful basis recorded.`
6. `Consent engine` — `A banner in your brand and a blocker that holds trackers
   until visitors agree.`

Deep-dives: pick the three that demo best on video-free screenshots — the page
builder, the consent banner designer, the reporting view.

Technical FAQ: hosting and data location, security posture, SSO plans, export,
integration approach ("we would rather build the integration you need than sell
you a marketplace").

### 4.3 /sell-training — resellers

- Hero eyebrow: `For training providers and resellers`
- Hero heading: `Turn what you know into what you sell`
- Hero body: `You have the expertise and the audience. BespokeLMS is the
  storefront, the delivery and the paperwork: a course business under your own
  name, without a platform badge that is not yours.`

Sections: `problem-solution` (their-brand-vs-yours, per-learner pricing),
`feature-showcase` ×3 (storefront and catalogue; selling to organisations rather
than individuals; enquiry-to-renewal with the CRM and marketing permissions),
`course-grid` (the live catalogue as proof), `faq` (can we use our own content;
can we migrate learners; how does revenue work), `cta`.

One paragraph in this page carries the compliance-as-sales-asset argument:

> `Your buyers audit their suppliers. When your platform records consent
> properly, sends marketing only to people who agreed, and produces training
> evidence on demand, compliance stops being your cost and becomes your pitch.`

### 4.4 /train-your-people — in-house

- Hero eyebrow: `For operators`
- Hero heading: `Every site, every shift, trained and provable`
- Hero body: `Compliance training across branches fails quietly: the record is
  the thing missing when the auditor asks. BespokeLMS keeps the training done,
  current and evidenced, per person, per role, per site.`

Sections: `feature-showcase` ×3 (role and refresher matrices; branch reporting;
the audit pack), `stat-row` (real figures), `faq` (rollout time; who administers
it; what happens to lapsed refreshers), `cta`.

### 4.5 /how-we-work — replaces Pricing

The page that converts the absence of a sign-up button into trust.

- Hero heading: `You will not find a sign-up button here`
- Hero body: `That is deliberate. Platforms you configure alone become shelfware
  with your logo on it. We deliver BespokeLMS as a partnership, and it starts
  with a conversation, not a card form.`

`feature-grid` as a numbered four-step journey:
1. `The conversation` — `What you sell or need to train, to whom, under what
   scrutiny. We will tell you plainly if we are not the right fit.`
2. `The shaping` — `We configure the platform to your structure: brand, domains,
   catalogue, organisations, reporting. You see your business in it before you
   commit to it.`
3. `The launch` — `Onboarding together, with your team trained on the console
   and your first clients or cohorts live.`
4. `The partnership` — `The platform keeps being built. What tenants need next
   shapes the roadmap, and you will know the people building it by name.`

`faq`: pricing philosophy (scope-based, stated bands if Andrew wishes), contract
length, data ownership and exit, migration support.

`cta`: `Start the conversation`.

### 4.6 /partners

Short page. `hero` → `rich-text` → `form`.

- Hero heading: `Your customers keep asking about training`
- Body: `If you run a platform for hospitality or food businesses, training is
  the request you keep routing elsewhere. BespokeLMS white-labels cleanly enough
  to carry your recommendation, and we build integrations rather than sell
  marketplace listings. Referral, reseller or embedded: worth a conversation.`

### 4.7 /about and /insights

Both already scaffolded in the CMS as drafts. About needs Andrew's real material:
the founding story for `rich-text` (the honest version — built out of running
TeachHQ and finding nothing worth white-labelling), four values for
`values-grid` (drafts: `Straight answers` / `Built, not bolted on` / `Your brand
first` / `Evidence over promises`, each with two supporting sentences), and the
founder photos, bios and LinkedIn URLs for `team-grid`. Insights launches with
the post-grid live the moment the first article publishes; three launch articles
are proposed in section 8.

### 4.8 /contact

`hero` (heading: `Tell us what you are building`) → `form` (name, company, role,
what they need — one free-text field, not a qualification questionnaire) →
`rich-text` (what happens next: `A reply from a person within one working day.
Then a call, if it makes sense for both of us.`).

The form's consent wording is dogfood: a genuine marketing-permission checkbox,
stored against the exact wording shown, exactly as the platform does for tenants.

---

## 5. Imagery system

The premium sites we benchmarked (Linear, Stripe, Airtable in the 2026 round-ups)
share one habit: the product is the imagery. No stock photography, no illustration
metaphors, no handshakes.

**Product frames.** The core asset type: real platform screenshots inside a
minimal browser frame — 12px radius, hairline border, one soft shadow, consistent
across the site. Captured at 2x from the real console showing the platform-owner
org or a consenting tenant's brand. Never a mocked-up interface: the "no dummy
data" rule applies to pixels too, because a prospect who later sees the real
product must recognise it.

**The self-referential shot.** The single most persuasive image available to us:
the BespokeLMS page builder editing the very homepage the visitor is reading.
Showcase D on the home page is built around it.

**Gradient fields.** Heroes use generated gradient backgrounds in the brand
palette — depth without a photograph, and no licensing, no third-party host, no
consent implications. Rendered as WebP, not CSS, so they are identical everywhere.

**Photography** only when real: founder portraits for the team grid, and client
workplaces only if a client supplies and approves them. Until then, none.

**Formats.** The media bucket refuses SVG deliberately, so logos and any line art
go in as 2x PNG or WebP. Every page gets a designed OG image (1200×630) — shares
into Slack and LinkedIn are part of the premium impression.

---

## 6. Motion system — the one engineering slice this plan needs

The renderer has no motion layer. Blocks arrive as server-rendered HTML and sit
still. An Apple-grade feel needs one, and it should be built once, in the site
layout, as a platform capability every tenant site inherits — not hand-coded into
our pages.

**Architecture.** One stylesheet and one script (~2KB, no dependencies) in the
public site layout. Block templates emit `data-reveal` attributes; an
IntersectionObserver adds `is-in` when a section enters the viewport; CSS
transitions do the rest. Children stagger via a `--reveal-index` custom property.
No animation library, no third-party host: the site that sells a tracker-blocking
consent engine loads zero third-party scripts itself. Analytics, when added, sits
behind our own banner.

**Tokens** (design-token system, so tenants inherit and can tune):
`--motion-s: 200ms`, `--motion-m: 450ms`, `--motion-l: 700ms`, easing
`cubic-bezier(0.22, 1, 0.36, 1)` (fast start, long settle — the "expensive" feel),
reveal distance 24px.

**The moves:**

- **M1 Reveal.** Sections fade up 24px over `--motion-m` as they enter; card
  children stagger at 60ms. The workhorse; applied by default to every block.
- **M2 Hero entrance.** On load, not scroll: eyebrow, heading, body, buttons rise
  in sequence at 80ms offsets. First impression of craft.
- **M3 Count-up.** Stat-row numbers animate from zero over 900ms when first seen.
  Numbers are server-rendered at final value; JS only animates the approach, so
  no-JS and reduced-motion visitors see truth instantly.
- **M4 Frame parallax.** Product frames in showcases translate vertically ~6%
  against scroll. Transform-only, subtle enough to feel like depth rather than a
  trick.
- **M5 Marquee.** Logo strip drifts at ~30s/loop, pauses on hover. Only enabled
  at five or more logos.
- **M6 Page cross-fade.** View Transitions API where the browser supports it,
  nothing where it does not. No SPA framework, no scroll-jacking, no pinned
  sections.

**Hard rules.** Transform and opacity only — nothing animates layout. Everything
readable with JS disabled. `prefers-reduced-motion` disables all six moves, full
stop; the consent module set the pattern that accessibility choices are honoured,
and the marketing site does not get an exception. Total motion JS budget 5KB.
Lighthouse performance ≥95 on 4G mobile is a launch gate, because a slow premium
site is a contradiction visitors notice in the first second.

---

## 7. Typography and design tokens

Scale is where "premium" mostly lives. Recommendations, applied through the
design-token system rather than hard-coded:

- Display face for headings with tight tracking (-0.02em) and a true bold —
  Inter Display class if we stay self-hosted and licence-free; body stays on the
  current UI face for continuity with the product.
- Hero type at `clamp(2.75rem, 6vw, 4.75rem)`, section headings
  `clamp(1.75rem, 3vw, 2.5rem)`, body at 1.125rem with 1.7 line height, measures
  capped at 65ch.
- Whitespace as a feature: section padding 96–128px on desktop. Half the Apple
  effect is simply room.
- Self-hosted fonts (`font-display: swap`), preloaded — no Google Fonts request,
  for the same consent-posture reason as the no-third-party-script rule.

---

## 8. Launch content for /insights

Three articles at launch so the post-grid opens populated, each doing sales work
without reading as sales:

1. *Why we put a consent engine inside a learning platform* — the PECR/GDPR
   argument, our credibility piece.
2. *The white-label test: twelve places your platform's brand leaks* — a checklist
   prospects will run against competitors, which we pass by construction.
3. *Training evidence an auditor will actually accept* — sector authority for the
   in-house audience.

---

## 9. Build order

1. **Copy sign-off** — Andrew reviews every drafted string in section 4; nothing
   enters the CMS before this.
2. **Motion slice** — the section 6 engineering work: tokens, stylesheet, script,
   `data-reveal` emission in block templates, reduced-motion test, budget test.
3. **Type and spacing tokens** — section 7 applied to the marketing surface.
4. **Home, How we work, Contact** — the minimum persuasive site; publish.
5. **Platform, Sell training, Train your people** — the depth pages; publish as
   screenshots are captured.
6. **About and Insights** — populated the moment Andrew's assets and the first
   article exist; the scaffolds are already in place as drafts.
7. **Partners** — after the first partner conversation shapes the wording.
8. **QA gate** — Lighthouse ≥95 mobile, reduced-motion pass, keyboard pass,
   consent banner live with analytics gated behind it, OG images on every page.

## 10. What only Andrew can supply

- Real statistics for the two stat-rows (courses, learners, organisations, years).
- Client logos with written permission (minimum three before the strip shows).
- One testimonial quote with a name and role attached, when a client will give it.
- Founder photos, bios and LinkedIn URLs for the team grid.
- The founding story, told plainly, for the About page.
- A decision on stating pricing bands on How we work, or scope-only.
- Sign-off on the voice: the copy above is written to sound like the platform's
  own docblocks — plain, specific, slightly dry. If that is not the public voice
  Andrew wants, better to correct it at this document than across ten pages.
