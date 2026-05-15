# Account Creation and Onboarding Recovery Phases

This document tracks the remaining work to make account creation, subscription activation, calendar connection, receptionist creation, and first-call onboarding reliable.

## Current Target Flow

1. User chooses a plan from the landing page.
2. User creates an account with email/password or Google.
3. Supabase Auth creates the auth user.
4. `public.users` profile row is created or repaired.
5. User completes checkout if no active subscription exists.
6. User connects Google Calendar.
7. User creates the first receptionist.
8. Backend provisions or attaches the business phone number.
9. User makes a test call.
10. `users.onboarding_completed_at` is set only after setup is meaningfully complete.

## Phase 1 - Stabilize Signup and Profile Creation

Status: implemented locally. Needs deployment and live Supabase trigger verification.

Goal: every new Auth user must have a valid `public.users` row and a predictable first route.

Tasks:

- Verify `supabase/migrations/001_initial_schema.sql` is applied in the live Supabase project.
- Confirm the `on_auth_user_created` trigger exists in Supabase SQL editor:

```sql
select trigger_name, event_object_table
from information_schema.triggers
where trigger_name = 'on_auth_user_created';
```

- Add a backend repair endpoint or helper that upserts `public.users` from the authenticated session if the trigger missed the row.
- Use that helper from the mobile app startup or first dashboard/onboarding API call.
- Keep [mobile/lib/screens/auth/signup_screen.dart](../../mobile/lib/screens/auth/signup_screen.dart) routing behavior:
  - immediate session + selected plan -> `/checkout?plan=<plan>`
  - immediate session + no plan -> `/dashboard`
  - email confirmation required -> `/login`

Acceptance checks:

- New email signup creates one `auth.users` row and one `public.users` row.
- New confirmed user lands in onboarding, not a blank dashboard.
- Signup from `/signup?plan=dev_test` preserves `dev_test` into checkout.

Implemented files:

- [backend/api/mobile_routes.py](../../backend/api/mobile_routes.py): added `POST /api/mobile/profile/ensure`.
- [mobile/lib/services/account_bootstrap_service.dart](../../mobile/lib/services/account_bootstrap_service.dart): calls the repair endpoint after session recovery/login.
- [mobile/lib/app.dart](../../mobile/lib/app.dart): starts and disposes the bootstrap service.
- [mobile/lib/screens/auth/signup_screen.dart](../../mobile/lib/screens/auth/signup_screen.dart): preserves selected plan for immediate-session email signup.

## Phase 2 - Preserve Plan Selection Across All Signup Methods

Status: implemented locally. Needs manual OAuth/signup verification before deployment.

Goal: plan selection must survive email signup, Google signup, and login-after-confirmation.

Tasks:

- Store pending selected plan locally before signup, for example `pending_plan_id`.
- Read pending plan after successful auth/session recovery.
- Send the user to `/checkout?plan=<pending_plan_id>` when the plan is still valid.
- Clear pending plan only after checkout starts or the user deliberately changes plan.
- Add equivalent behavior to Google signup in [mobile/lib/screens/auth/signup_screen.dart](../../mobile/lib/screens/auth/signup_screen.dart).

Acceptance checks:

- Landing page Starter button -> signup -> checkout opens Starter.
- Landing page DEV test button -> signup -> checkout opens DEV test.
- Google signup does not drop the selected plan.
- Invalid or removed plan IDs fall back to the plan picker.

Implemented files:

- [mobile/lib/services/pending_plan_service.dart](../../mobile/lib/services/pending_plan_service.dart): stores, validates, reads, and clears pending plan IDs.
- [mobile/lib/screens/landing/landing_screen.dart](../../mobile/lib/screens/landing/landing_screen.dart): saves selected plans before routing to signup; clears stale plans for generic signup.
- [mobile/lib/screens/auth/signup_screen.dart](../../mobile/lib/screens/auth/signup_screen.dart): saves selected plans before email or Google signup.
- [mobile/lib/app.dart](../../mobile/lib/app.dart): routes authenticated users with a pending plan to checkout after profile repair.
- [mobile/lib/screens/checkout/checkout_screen.dart](../../mobile/lib/screens/checkout/checkout_screen.dart): clears pending plan once checkout starts and rejects invalid plan IDs.
- [mobile/test/pending_plan_service_test.dart](../../mobile/test/pending_plan_service_test.dart): covers save/read/clear/invalid behavior.

## Phase 3 - Centralize Onboarding State

Status: implemented locally. Needs manual new-account verification against production data.

Goal: the app should not calculate onboarding progress by manually querying several Supabase tables from Flutter.

Tasks:

- Add a backend endpoint:

```text
GET /api/mobile/onboarding-status
```

- Return a single JSON object:

```json
{
  "hasProfile": true,
  "hasActiveSubscription": true,
  "hasCalendar": true,
  "hasBusiness": true,
  "hasReceptionist": false,
  "hasBusinessPhoneNumber": false,
  "phoneNumber": null,
  "currentStep": "create_receptionist"
}
```

- Make [mobile/lib/screens/onboarding/onboarding_screen.dart](../../mobile/lib/screens/onboarding/onboarding_screen.dart) use this endpoint instead of direct Supabase table reads.
- Include backend repair logic for missing profile/business records.

Acceptance checks:

- Onboarding still loads when a business record does not exist yet.
- Communication setup no longer returns a dead-end 404 for new users.
- State is consistent after app restart.

Implemented files:

- [backend/api/mobile_routes.py](../../backend/api/mobile_routes.py): added `GET /api/mobile/onboarding-status`, including profile repair, default business repair, communication row repair, and centralized setup flags.
- [mobile/lib/screens/onboarding/onboarding_screen.dart](../../mobile/lib/screens/onboarding/onboarding_screen.dart): now loads onboarding state from the backend endpoint instead of querying multiple Supabase tables directly.

## Phase 4 - Fix Calendar Connection UX

Status: implemented locally. Needs manual browser/deep-link verification on macOS/iOS/Android.

Goal: after Google Calendar connects, the mobile app should know immediately.

Tasks:

- Keep backend Google OAuth callback in [backend/api/google_routes.py](../../backend/api/google_routes.py).
- Change successful mobile callback behavior from static HTML-only success to a mobile deep link:

```text
echodesk://google-callback?success=1
```

- Keep the HTML fallback for desktop/browser users.
- Ensure Supabase Google Auth and Google Calendar OAuth are treated as separate flows:
  - Supabase Auth Google login: `echodesk://auth-callback`
  - Calendar connect: `echodesk://google-callback`

Acceptance checks:

- Calendar connection returns to the app or displays a clear browser close page.
- App shows “Google Calendar connected”.
- Onboarding advances from Calendar to Create Receptionist without manual restart.

Implemented files:

- [backend/api/google_routes.py](../../backend/api/google_routes.py): successful mobile Calendar OAuth now returns an HTML fallback page that immediately opens `echodesk://google-callback?success=1`.
- [mobile/lib/services/deep_link_handler.dart](../../mobile/lib/services/deep_link_handler.dart): Google Calendar success deep links now trigger an app callback in addition to the snackbar.
- [mobile/lib/app.dart](../../mobile/lib/app.dart): refreshes the current onboarding/settings route when Calendar connects so the UI can advance without app restart.

## Phase 5 - Tighten Subscription Gating

Status: implemented locally. Needs migration deployment plus one live Stripe checkout/webhook verification.

Goal: onboarding should only ask for checkout when the backend agrees the user does not have a valid plan.

Tasks:

- Use backend billing state instead of direct `users.subscription_status` reads in onboarding.
- Treat valid Stripe states deliberately:
  - `active`
  - optionally `trialing`
  - block `inactive`, `past_due`, `canceled`, `incomplete`
- Keep Stripe checkout session sync through:

```text
POST /api/mobile/sync-session
```

- Confirm DEV test plan is represented consistently in:
  - [mobile/lib/models/plan.dart](../../mobile/lib/models/plan.dart)
  - [backend/stripe_plans.py](../../backend/stripe_plans.py)
  - Stripe Dashboard product/price metadata
  - Supabase `subscriptions` / `user_plans`

Acceptance checks:

- Successful Stripe checkout updates the app without manual database edits.
- Returning from checkout triggers sync and dashboard/onboarding reflects active plan.
- DEV test does not show Enterprise.

Implemented files:

- [backend/billing/subscriptions.py](../../backend/billing/subscriptions.py): added a single billing access decision helper; only `active` and `trialing` grant access.
- [backend/billing/stripe_sync.py](../../backend/billing/stripe_sync.py): maps incomplete/unknown Stripe states to blocked database states instead of defaulting to active.
- [backend/api/mobile_routes.py](../../backend/api/mobile_routes.py): onboarding status and receptionist creation now use backend billing state.
- [backend/stripe_plans.py](../../backend/stripe_plans.py): aligned Starter, Pro, and DEV test metadata prices with the current mobile/Stripe plan set.
- [mobile/lib/models/user_profile.dart](../../mobile/lib/models/user_profile.dart), [mobile/lib/services/dashboard_service.dart](../../mobile/lib/services/dashboard_service.dart), and [mobile/lib/screens/receptionists/receptionists_screen.dart](../../mobile/lib/screens/receptionists/receptionists_screen.dart): treat `trialing` as valid access and keep blocked states locked out.
- [supabase/migrations/041_subscription_plan_catalog_alignment.sql](../../supabase/migrations/041_subscription_plan_catalog_alignment.sql): allows and seeds `business`, `dev_test`, and `payg`; removes Enterprise from the plan catalog.
- [backend/tests/test_billing_subscriptions.py](../../backend/tests/test_billing_subscriptions.py): covers subscription access gating.

## Phase 6 - Business and Communication Setup

Goal: every subscribed user can create a receptionist and reach communication setup without missing-record errors.

Tasks:

- Keep auto-creation of the default business in [backend/api/mobile/communication.py](../../backend/api/mobile/communication.py).
- Add the same default-business repair to any endpoint that depends on business records.
- Decide whether `business_phone_numbers.status = failed` is appropriate before any number provisioning attempt. Prefer `not_started` or `missing` for a clean first-time state.
- Ensure the communication setup screen can display:
  - no number yet
  - provisioning
  - active
  - failed with retry

Acceptance checks:

- New account can open Settings -> Communication setup without 404.
- New account can create the first receptionist.
- Failed Telnyx provisioning shows a useful recovery action.

## Phase 7 - Receptionist Creation and Onboarding Completion

Goal: onboarding completion should reflect a real setup milestone, not a skipped flow.

Tasks:

- Keep the route guard fix in [mobile/lib/app_router.dart](../../mobile/lib/app_router.dart):
  - allow `/onboarding`
  - allow `/receptionists/create`
  - allow settings/checkout/help/call routes
- Keep [mobile/lib/screens/receptionists/create_receptionist_screen.dart](../../mobile/lib/screens/receptionists/create_receptionist_screen.dart) returning `context.pop(true)` when opened from onboarding.
- Reconsider the “I’ll do this later” button:
  - Option A: remove it.
  - Option B: leave onboarding incomplete and route user to dashboard with a persistent setup banner.
  - Option C: mark a separate `onboarding_dismissed_at`, not `onboarding_completed_at`.
- Mark `onboarding_completed_at` only after:
  - calendar connected
  - subscription valid
  - receptionist exists
  - test number exists or phone provisioning is intentionally skipped

Acceptance checks:

- Create Receptionist from onboarding returns to onboarding and advances to Test Call.
- “Done” from create receptionist does not trap the user on the wrong route.
- Onboarding is not marked complete for a user who skipped all setup.

## Phase 8 - Copy, Screens, and User Trust

Goal: app text should match the current shared business-number architecture.

Tasks:

- Avoid old language:
  - “default phone”
  - “each receptionist gets a dedicated phone number”
- Use current language:
  - “business number”
  - “assistant answers on your business line”
- Keep copy updated in:
  - [mobile/lib/screens/onboarding/onboarding_screen.dart](../../mobile/lib/screens/onboarding/onboarding_screen.dart)
  - [mobile/lib/screens/dashboard/dashboard_screen.dart](../../mobile/lib/screens/dashboard/dashboard_screen.dart)
  - [mobile/lib/screens/help/help_screen.dart](../../mobile/lib/screens/help/help_screen.dart)
  - [mobile/lib/screens/landing/landing_screen.dart](../../mobile/lib/screens/landing/landing_screen.dart)

Acceptance checks:

- No references remain to default phone setup.
- No screen promises a dedicated number per receptionist unless the backend actually provisions that.

## Phase 9 - QA Script Before Release

Run these checks before treating onboarding as fixed.

Local static checks:

```bash
cd "/Users/pedromartins/Documents/AI Call handle/backend"
python3 -m py_compile api/mobile_routes.py api/stripe_routes.py stripe_plans.py api/mobile/communication.py

cd "/Users/pedromartins/Documents/AI Call handle/mobile"
flutter analyze
```

Manual test matrix:

- New email signup with no selected plan.
- New email signup from Starter plan.
- New email signup from DEV test plan.
- Google signup from a selected plan.
- Confirmed email login after email verification.
- Checkout success return and session sync.
- Calendar connect from onboarding.
- Calendar connect from settings.
- Receptionist creation from onboarding.
- Receptionist creation from Receptionists tab.
- Communication setup on brand-new account.
- App restart after each major step.

Production checks:

```bash
ssh root@209.126.87.50
systemctl status echodesk-backend --no-pager
journalctl -u echodesk-backend -n 100 --no-pager
curl -fsS https://echodesk.us/health
```

## Phase 10 - Deployment Checklist

Before deploying:

- Confirm `.env` has correct Supabase URL and service role key.
- Confirm Stripe keys and price IDs are live-mode compatible.
- Confirm Google OAuth redirect URI:

```text
https://echodesk.us/api/google/callback
```

- Confirm mobile app uses production API base URL:

```text
https://echodesk.us
```

- Confirm Telnyx webhook points to the production backend.
- Confirm Deepgram, Grok, and Google TTS keys are present on the VPS.

After deploying:

```bash
ssh root@209.126.87.50
cd /opt/echodesk/app
git pull
systemctl restart echodesk-backend
systemctl status echodesk-backend --no-pager
curl -fsS https://echodesk.us/health
```

Then run one complete real signup-to-test-call flow.
