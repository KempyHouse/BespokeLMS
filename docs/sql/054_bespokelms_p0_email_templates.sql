-- 054_bespokelms_p0_email_templates.sql
--
-- The P0 email templates: the thirteen new ones (forgot_password already
-- existed and is backfilled by 053).
--
-- Bodies are SEMANTIC HTML only, per the rule migrations 025-027 established:
-- the template carries meaning and the BrandedEmailRenderer paints every
-- colour, font and radius from the tenant's brand kit at send time. body_text
-- is the plain-text alternative, authored rather than stripped from the markup,
-- and transmitted first in the multipart body.
--
-- Every row is is_protected (a tenant copies it rather than editing the
-- original) and is_classification_locked (the category cannot later be moved
-- to marketing, which is what the trigger in 050 enforces).
--
-- Research: docs/BespokeLMS-System-Emails-Research.md section 3.

insert into outbound_templates
  (organization_id, channel, category, key, event_key, name, subject, body_html, body_text, variables,
   is_protected, is_classification_locked, is_active, locale)
values
(null, 'email', 'system', 'password_changed', 'password_changed',
 'Password changed',
 'Your {{app_name}} password was changed',
 '<p>Hi {{user_name}}</p>
<p>The password on your {{app_name}} account was changed on {{changed_at}}.</p>
<p>The change came from {{device}}, {{location}}. If that was you, there is nothing to do.</p>
<p><strong>If it was not you</strong>, someone else may have access to your account. Secure it now.</p>
<p class="center"><a href="{{security_url}}" class="button">Secure my account</a></p>
<p>That link signs you out everywhere and starts a fresh password reset. You can also reach us at <a href="mailto:{{support_email}}">{{support_email}}</a>.</p>',
 'Hi {{user_name}}

The password on your {{app_name}} account was changed on {{changed_at}}.

The change came from {{device}}, {{location}}. If that was you, there is nothing to do.

If it was not you, someone else may have access to your account. Secure it now by opening this link, which signs you out everywhere and starts a fresh password reset:

{{security_url}}

You can also reach us at {{support_email}}.',
 '[{"key":"app_name","label":"Platform or tenant name","example":"BespokeLMS"},{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"changed_at","label":"When the change happened","example":"25 July 2026 at 14:32 (BST)"},{"key":"device","label":"Browser and operating system","example":"Chrome on Windows"},{"key":"location","label":"Approximate location","example":"Leeds, United Kingdom"},{"key":"security_url","label":"Account lockdown page","example":"https://app.bespokelms.com/security"},{"key":"support_email","label":"Support contact address","example":"support@bespokelms.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'system', 'email_change_confirm', 'email_change_confirm',
 'Confirm new email address',
 'Confirm your new email address for {{app_name}}',
 '<p>Hi {{user_name}}</p>
<p>You asked to change the email address on your {{app_name}} account to this one. Confirm it below and we will make the switch.</p>
<p class="center"><a href="{{confirm_url}}" class="button">Confirm this address</a></p>
<p>If the button does not work, copy and paste this link into your browser:<br><a href="{{confirm_url}}">{{confirm_url}}</a></p>
<p>This link expires in {{expires_in}} and can only be used once. Until you confirm, your account keeps using {{old_email}}.</p>
<p>Did not ask for this? Ignore this email and nothing changes.</p>',
 'Hi {{user_name}}

You asked to change the email address on your {{app_name}} account to this one. Confirm it by opening this link:

{{confirm_url}}

This link expires in {{expires_in}} and can only be used once. Until you confirm, your account keeps using {{old_email}}.

Did not ask for this? Ignore this email and nothing changes.',
 '[{"key":"app_name","label":"Platform or tenant name","example":"BespokeLMS"},{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"confirm_url","label":"Confirmation link","example":"https://app.bespokelms.com/auth/confirm-email"},{"key":"expires_in","label":"How long the link stays valid","example":"60 minutes"},{"key":"old_email","label":"The address currently on the account","example":"andrew@example.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'system', 'email_change_notify', 'email_change_notify',
 'Email address change requested',
 'A change was requested to your {{app_name}} email address',
 '<p>Hi {{user_name}}</p>
<p>Someone asked to move your {{app_name}} account from this address to {{new_email}} on {{requested_at}}.</p>
<p>The change only takes effect once the new address is confirmed. Until then you can still sign in here as normal.</p>
<p><strong>If you did not request this</strong>, cancel it now and change your password. Someone may have access to your account.</p>
<p class="center"><a href="{{cancel_url}}" class="button">Cancel this change</a></p>
<p>Questions? Contact <a href="mailto:{{support_email}}">{{support_email}}</a>.</p>',
 'Hi {{user_name}}

Someone asked to move your {{app_name}} account from this address to {{new_email}} on {{requested_at}}.

The change only takes effect once the new address is confirmed. Until then you can still sign in here as normal.

If you did not request this, cancel it now and change your password. Someone may have access to your account. Open this link to cancel:

{{cancel_url}}

Questions? Contact {{support_email}}.',
 '[{"key":"app_name","label":"Platform or tenant name","example":"BespokeLMS"},{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"new_email","label":"The proposed new address","example":"a.kemp@example.com"},{"key":"requested_at","label":"When the change was requested","example":"25 July 2026 at 14:32 (BST)"},{"key":"cancel_url","label":"Cancel-the-change link","example":"https://app.bespokelms.com/auth/cancel-email-change"},{"key":"support_email","label":"Support contact address","example":"support@bespokelms.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'system', 'account_invited', 'account_invited',
 'Invitation to join',
 '{{inviter_name}} has invited you to {{tenant_name}}',
 '<p>Hi {{user_name}}</p>
<p>{{inviter_name}} ({{inviter_email}}) has invited you to join <strong>{{tenant_name}}</strong> on {{app_name}} as {{role_name}}.</p>
<p class="center"><a href="{{accept_url}}" class="button">Accept the invitation</a></p>
<p>If the button does not work, copy and paste this link into your browser:<br><a href="{{accept_url}}">{{accept_url}}</a></p>
<p>The invitation expires on {{expires_at}} and can only be used once.</p>
<p>We have your email address because {{tenant_name}} gave it to us so they could set up your training. You can read how we handle your information in our <a href="{{privacy_url}}">privacy notice</a>.</p>
<p>Not expecting this? Ignore it, or tell us at <a href="mailto:{{support_email}}">{{support_email}}</a>.</p>',
 'Hi {{user_name}}

{{inviter_name}} ({{inviter_email}}) has invited you to join {{tenant_name}} on {{app_name}} as {{role_name}}.

Accept the invitation by opening this link:

{{accept_url}}

The invitation expires on {{expires_at}} and can only be used once.

We have your email address because {{tenant_name}} gave it to us so they could set up your training. You can read how we handle your information in our privacy notice: {{privacy_url}}

Not expecting this? Ignore it, or tell us at {{support_email}}.',
 '[{"key":"app_name","label":"Platform or tenant name","example":"BespokeLMS"},{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"tenant_name","label":"Organisation","example":"Turner Price"},{"key":"inviter_name","label":"Who sent the invitation","example":"Sarah Whitfield"},{"key":"inviter_email","label":"Inviter email address","example":"sarah@turnerprice.com"},{"key":"role_name","label":"Role being granted","example":"Team manager"},{"key":"accept_url","label":"Invitation link","example":"https://tp.bespokelms.com/invite/accept"},{"key":"expires_at","label":"Expiry date","example":"1 August 2026"},{"key":"privacy_url","label":"Privacy notice, no sign-in required","example":"https://bespokelms.com/privacy"},{"key":"support_email","label":"Support contact address","example":"support@bespokelms.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'system', 'role_changed', 'role_changed',
 'Access changed',
 'Your access to {{tenant_name}} has changed',
 '<p>Hi {{user_name}}</p>
<p>{{actor_name}} changed your role on {{tenant_name}} from <strong>{{old_role}}</strong> to <strong>{{new_role}}</strong> on {{changed_at}}.</p>
<p>This changes what you can see and do. Next time you sign in you may find new areas available, or some no longer there.</p>
<p class="center"><a href="{{app_url}}" class="button">Sign in</a></p>
<p>If this looks wrong, contact <a href="mailto:{{support_email}}">{{support_email}}</a>.</p>',
 'Hi {{user_name}}

{{actor_name}} changed your role on {{tenant_name}} from {{old_role}} to {{new_role}} on {{changed_at}}.

This changes what you can see and do. Next time you sign in you may find new areas available, or some no longer there.

Sign in: {{app_url}}

If this looks wrong, contact {{support_email}}.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"tenant_name","label":"Organisation","example":"Turner Price"},{"key":"actor_name","label":"Administrator who made the change","example":"Sarah Whitfield"},{"key":"old_role","label":"Previous role","example":"Learner"},{"key":"new_role","label":"New role","example":"Team manager"},{"key":"changed_at","label":"When the change happened","example":"25 July 2026 at 14:32 (BST)"},{"key":"app_url","label":"Sign-in link","example":"https://tp.bespokelms.com"},{"key":"support_email","label":"Support contact address","example":"support@bespokelms.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'system', 'sending_domain_broken', 'sending_domain_broken',
 'Sending domain failing',
 'Action needed: {{tenant_name}} emails are not being delivered',
 '<p>Hi {{user_name}}</p>
<p>We can no longer send email as <strong>{{sending_domain}}</strong>. Until this is fixed, nobody at {{tenant_name}} will receive anything from the platform: invitations, password resets, training reminders or certificates.</p>
<p>What failed on the last check at {{checked_at}}:</p>
<ul>
<li>{{failure_summary}}</li>
</ul>
<p>This almost always means a DNS record was changed or removed.</p>
<p class="center"><a href="{{domains_url}}" class="button">Review the domain settings</a></p>
<p>We will keep checking and let you know when it is working again. If you want a hand, contact <a href="mailto:{{support_email}}">{{support_email}}</a>.</p>',
 'Hi {{user_name}}

We can no longer send email as {{sending_domain}}. Until this is fixed, nobody at {{tenant_name}} will receive anything from the platform: invitations, password resets, training reminders or certificates.

What failed on the last check at {{checked_at}}:

- {{failure_summary}}

This almost always means a DNS record was changed or removed.

Review the domain settings: {{domains_url}}

We will keep checking and let you know when it is working again. If you want a hand, contact {{support_email}}.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"tenant_name","label":"Organisation","example":"Turner Price"},{"key":"sending_domain","label":"The sending domain","example":"mail.turnerprice.com"},{"key":"checked_at","label":"When we last checked","example":"25 July 2026 at 06:00 (BST)"},{"key":"failure_summary","label":"Which record failed","example":"The DKIM record at resend._domainkey no longer resolves"},{"key":"domains_url","label":"Domain settings page","example":"https://app.bespokelms.com/platform/domains"},{"key":"support_email","label":"Support contact address","example":"support@bespokelms.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'enrollment_assigned', 'enrollment_assigned',
 'Course assigned',
 '{{course_title}} has been added to your training',
 '<p>Hi {{user_name}}</p>
<p>{{tenant_name}} has assigned you <strong>{{course_title}}</strong>.</p>
<ul>
<li>Due by {{due_date}}</li>
<li>Takes about {{duration}}</li>
</ul>
<p class="center"><a href="{{course_url}}" class="button">Start the course</a></p>
<p>You can pick it up and put it down as you like. Your progress is saved as you go.</p>
<p>Not sure why this was assigned? Speak to {{tenant_name}}, or contact <a href="mailto:{{support_email}}">{{support_email}}</a>.</p>',
 'Hi {{user_name}}

{{tenant_name}} has assigned you {{course_title}}.

Due by {{due_date}}. Takes about {{duration}}.

Start the course: {{course_url}}

You can pick it up and put it down as you like. Your progress is saved as you go.

Not sure why this was assigned? Speak to {{tenant_name}}, or contact {{support_email}}.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"tenant_name","label":"Organisation","example":"Turner Price"},{"key":"course_title","label":"Course title","example":"Food Safety Level 2"},{"key":"due_date","label":"Due date","example":"8 August 2026"},{"key":"duration","label":"Estimated time to complete","example":"45 minutes"},{"key":"course_url","label":"Link to the course","example":"https://tp.bespokelms.com/my/courses/food-safety-level-2"},{"key":"support_email","label":"Support contact address","example":"support@bespokelms.com"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'training_due', 'training_due',
 'Training due',
 '{{course_title}} is due on {{due_date}}',
 '<p>Hi {{user_name}}</p>
<p><strong>{{course_title}}</strong> is due on {{due_date}}, which is {{days_phrase}}.</p>
<p>You are {{progress_pct}}% of the way through.</p>
<p class="center"><a href="{{course_url}}" class="button">Continue the course</a></p>
<p>Already finished it? It can take a few minutes for your record to catch up.</p>',
 'Hi {{user_name}}

{{course_title}} is due on {{due_date}}, which is {{days_phrase}}.

You are {{progress_pct}}% of the way through.

Continue the course: {{course_url}}

Already finished it? It can take a few minutes for your record to catch up.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"course_title","label":"Course title","example":"Food Safety Level 2"},{"key":"due_date","label":"Due date","example":"8 August 2026"},{"key":"days_phrase","label":"How far off the date is, in words","example":"in 7 days"},{"key":"progress_pct","label":"Progress so far","example":"40"},{"key":"course_url","label":"Link to the course","example":"https://tp.bespokelms.com/my/courses/food-safety-level-2"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'course_completed', 'course_completed',
 'Course completed',
 'You have completed {{course_title}}',
 '<p>Hi {{user_name}}</p>
<p>You finished <strong>{{course_title}}</strong> on {{completed_at}}. That is it done.</p>
<p class="center"><a href="{{record_url}}" class="button">View your training record</a></p>
<p>Your record is always there when you sign in.</p>',
 'Hi {{user_name}}

You finished {{course_title}} on {{completed_at}}. That is it done.

View your training record: {{record_url}}

Your record is always there when you sign in.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"course_title","label":"Course title","example":"Food Safety Level 2"},{"key":"completed_at","label":"When it was completed","example":"25 July 2026"},{"key":"record_url","label":"Link to the learner training record","example":"https://tp.bespokelms.com/my/record"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'certificate_issued', 'certificate_issued',
 'Certificate issued',
 'Your certificate for {{course_title}}',
 '<p>Hi {{user_name}}</p>
<p>Your certificate for <strong>{{course_title}}</strong> was issued on {{issued_at}}.</p>
<ul>
<li>Certificate number {{certificate_number}}</li>
<li>Valid until {{expires_at}}</li>
</ul>
<p class="center"><a href="{{certificate_url}}" class="button">Download your certificate</a></p>
<p>You will need to sign in to download it. We will remind you before it expires.</p>',
 'Hi {{user_name}}

Your certificate for {{course_title}} was issued on {{issued_at}}.

Certificate number {{certificate_number}}. Valid until {{expires_at}}.

Download your certificate: {{certificate_url}}

You will need to sign in to download it. We will remind you before it expires.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"course_title","label":"Course title","example":"Food Safety Level 2"},{"key":"issued_at","label":"Issue date","example":"25 July 2026"},{"key":"certificate_number","label":"Certificate reference","example":"TP-FS2-004182"},{"key":"expires_at","label":"Expiry date","example":"25 July 2029"},{"key":"certificate_url","label":"Authenticated download link","example":"https://tp.bespokelms.com/my/certificates/004182"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'certificate_expiring', 'certificate_expiring',
 'Certificate expiring',
 'Your {{course_title}} certificate expires on {{expires_at}}',
 '<p>Hi {{user_name}}</p>
<p>Your certificate for <strong>{{course_title}}</strong> expires on {{expires_at}}, which is {{days_phrase}}.</p>
<p>To stay certified you will need to take the course again before then.</p>
<p class="center"><a href="{{course_url}}" class="button">Start the refresher</a></p>
<p>If you have already renewed, you can ignore this.</p>',
 'Hi {{user_name}}

Your certificate for {{course_title}} expires on {{expires_at}}, which is {{days_phrase}}.

To stay certified you will need to take the course again before then.

Start the refresher: {{course_url}}

If you have already renewed, you can ignore this.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"course_title","label":"Course title","example":"Food Safety Level 2"},{"key":"expires_at","label":"Expiry date","example":"25 October 2026"},{"key":"days_phrase","label":"How far off the date is, in words","example":"in 90 days"},{"key":"course_url","label":"Link to the course","example":"https://tp.bespokelms.com/my/courses/food-safety-level-2"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'certificate_expired', 'certificate_expired',
 'Certificate expired',
 'Your {{course_title}} certificate has expired',
 '<p>Hi {{user_name}}</p>
<p>Your certificate for <strong>{{course_title}}</strong> expired on {{expires_at}}. You are no longer certified for this.</p>
<p class="center"><a href="{{course_url}}" class="button">Renew now</a></p>
<p>Depending on your role this may affect the work you are allowed to do, so it is worth sorting quickly. Speak to {{tenant_name}} if you are not sure.</p>',
 'Hi {{user_name}}

Your certificate for {{course_title}} expired on {{expires_at}}. You are no longer certified for this.

Renew now: {{course_url}}

Depending on your role this may affect the work you are allowed to do, so it is worth sorting quickly. Speak to {{tenant_name}} if you are not sure.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"tenant_name","label":"Organisation","example":"Turner Price"},{"key":"course_title","label":"Course title","example":"Food Safety Level 2"},{"key":"expires_at","label":"Expiry date","example":"25 July 2026"},{"key":"course_url","label":"Link to the course","example":"https://tp.bespokelms.com/my/courses/food-safety-level-2"}]'::jsonb,
 true, true, true, 'en-GB'),

(null, 'email', 'transactional', 'course_now_available', 'course_now_available',
 'Course now available',
 '{{course_title}} is now available',
 '<p>Hi {{user_name}}</p>
<p>You asked to be told when <strong>{{course_title}}</strong> was ready. It is available now.</p>
<p class="center"><a href="{{course_url}}" class="button">Take a look</a></p>
<p>This is the only email you will get about it. We will not send you anything else unless you ask.</p>',
 'Hi {{user_name}}

You asked to be told when {{course_title}} was ready. It is available now.

Take a look: {{course_url}}

This is the only email you will get about it. We will not send you anything else unless you ask.',
 '[{"key":"user_name","label":"Recipient name","example":"Andrew"},{"key":"course_title","label":"Course title","example":"Allergen Awareness"},{"key":"course_url","label":"Link to the course","example":"https://tp.bespokelms.com/courses/allergen-awareness"}]'::jsonb,
 true, true, true, 'en-GB');
