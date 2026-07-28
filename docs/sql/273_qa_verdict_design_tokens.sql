-- 273: QA & Verification — verdict and gate design tokens.
--
-- Tokens land before any markup that uses them; that is the platform standard
-- and the reason this file is numbered ahead of the schema it dresses.
--
-- Why a new family rather than borrowing the Board stage palette: a stage
-- colour is named for where a card sits in a pipeline, a verdict is named for
-- what somebody found when they looked. They happen to want similar hues today,
-- which is exactly the trap PREVENTION.md section 6 describes — "for every
-- colour class, ask what the token is named for, not what it currently equals.
-- If the answer is 'it's the right shade', it is the wrong token." A run that
-- failed is not a card that is blocked, and the two will drift the first time
-- somebody restyles the board.
--
-- Four verdicts, one waiver:
--   pass     a case did what it said it would
--   fail     it did not
--   blocked  it could not be reached to find out
--   skipped  it was deliberately not run, with a reason
--   waived   a gate was crossed despite an unmet requirement, on the record
--
-- Values inherit from the RAG family so a tenant restyling their palette moves
-- these with it, and every -soft pairing keeps its own -ink where text sits on
-- it. themeable is false throughout: a tenant must not be able to make a failed
-- verification look like a passing one.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- connector as migration 273_qa_verdict_design_tokens.
--
-- Companion change, required in the same commit or these classes compile to
-- nothing: the matching declarations in the @theme static block of
-- resources/css/app.css in the bespokelms-app repo.

insert into public.design_tokens
    (key, css_var, type, default_value, dark_value, themeable, category, editor_group,
     label, helper, sort_order, inherits_from)
values
    ('color-verdict-pass', '--color-verdict-pass', 'color', '#059669', null, false,
     'Quality', null, 'Verdict: pass',
     'A test case did what it said it would.', 320, 'color-rag-green'),

    ('color-verdict-pass-soft', '--color-verdict-pass-soft', 'color', '#ecfdf5', '#0f2a1f', false,
     'Quality', null, 'Verdict: pass — surface',
     'The pale background a passing result sits on.', 321, 'color-rag-green-soft'),

    ('color-verdict-pass-ink', '--color-verdict-pass-ink', 'color', '#047857', '#5ddba8', false,
     'Quality', null, 'Verdict: pass — text',
     'Passing text on its own surface, contrast-tuned separately.', 322, 'color-rag-green-ink'),

    ('color-verdict-fail', '--color-verdict-fail', 'color', '#e5484d', null, false,
     'Quality', null, 'Verdict: fail',
     'A test case did not do what it said it would.', 323, 'color-rag-red'),

    ('color-verdict-fail-soft', '--color-verdict-fail-soft', 'color', '#fef2f2', '#2a1618', false,
     'Quality', null, 'Verdict: fail — surface',
     'The pale background a failing result sits on.', 324, 'color-rag-red-soft'),

    ('color-verdict-fail-ink', '--color-verdict-fail-ink', 'color', '#b42318', '#ff9d9d', false,
     'Quality', null, 'Verdict: fail — text',
     'Failing text on its own surface, contrast-tuned separately.', 325, 'color-rag-red-ink'),

    ('color-verdict-blocked', '--color-verdict-blocked', 'color', '#d97706', null, false,
     'Quality', null, 'Verdict: blocked',
     'The case could not be reached to find out either way.', 326, 'color-rag-amber'),

    ('color-verdict-blocked-soft', '--color-verdict-blocked-soft', 'color', '#fffbeb', '#2a2211', false,
     'Quality', null, 'Verdict: blocked — surface',
     'The pale background a blocked result sits on.', 327, 'color-rag-amber-soft'),

    ('color-verdict-blocked-ink', '--color-verdict-blocked-ink', 'color', '#b45309', '#f0b352', false,
     'Quality', null, 'Verdict: blocked — text',
     'Blocked text on its own surface, contrast-tuned separately.', 328, 'color-rag-amber-ink'),

    ('color-verdict-skipped', '--color-verdict-skipped', 'color', '#64748b', '#9fb1c0', false,
     'Quality', null, 'Verdict: skipped',
     'Deliberately not run, with a reason on the record.', 329, 'color-ink-soft'),

    ('color-verdict-skipped-soft', '--color-verdict-skipped-soft', 'color', '#f1f5f9', '#1b2732', false,
     'Quality', null, 'Verdict: skipped — surface',
     'The pale background a skipped result sits on.', 330, 'color-line-soft'),

    ('color-gate-waived', '--color-gate-waived', 'color', '#7c3aed', null, false,
     'Quality', null, 'Gate: waived',
     'A gate crossed despite an unmet requirement, named and reasoned.', 331, null),

    ('color-gate-waived-soft', '--color-gate-waived-soft', 'color', '#f5f3ff', '#221733', false,
     'Quality', null, 'Gate: waived — surface',
     'The pale background a waiver sits on.', 332, null),

    ('color-gate-waived-ink', '--color-gate-waived-ink', 'color', '#6d28d9', '#c4a8ff', false,
     'Quality', null, 'Gate: waived — text',
     'Waiver text on its own surface, contrast-tuned separately.', 333, null)
on conflict (key) do nothing;
