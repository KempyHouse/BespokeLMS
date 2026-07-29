-- 279: how loud the bell is allowed to be.
--
-- The header's notification counter is going live (a poll keeps it honest
-- between page loads) and a new notification now makes a sound. Sound imposed
-- on a person is a preference by definition, so the profile gains one:
-- notification_preferences, jsonb, currently {"sound": bool, "volume": 0-100}.
--
-- NULL MEANS NEVER CHOSEN, exactly as reading_preferences established: an
-- untouched preference follows the platform default (sound on, volume 70) and
-- keeps following it if the default improves; a saved choice is that person's
-- and does not move. The writer stores null for an empty set for the same
-- reason.
--
-- The CHECK mirrors brand_kits.logo_fit's lesson from earlier today: a jsonb
-- column enforces nothing by itself, and the application clamp is one
-- deployment away from being forgotten. Object-or-null, sound boolean when
-- present, volume 0-100 when present.
--
-- Applied to Supabase project pqmdtqsscyltykgcwwus via the Supabase MCP
-- on 2026-07-28.

alter table public.profiles
    add column if not exists notification_preferences jsonb;

alter table public.profiles
    add constraint profiles_notification_preferences_sane check (
        notification_preferences is null
        or (
            jsonb_typeof(notification_preferences) = 'object'
            and (
                not notification_preferences ? 'sound'
                or jsonb_typeof(notification_preferences -> 'sound') = 'boolean'
            )
            and (
                not notification_preferences ? 'volume'
                or (
                    jsonb_typeof(notification_preferences -> 'volume') = 'number'
                    and (notification_preferences ->> 'volume')::numeric between 0 and 100
                )
            )
        )
    );

comment on column public.profiles.notification_preferences is
    'How notifications behave for this person: {"sound": bool, "volume": 0-100}. Null = never chosen; the platform defaults (sound on, volume 70) apply.';
