# App Store Connect setup for EchoDesk subscriptions

Pedro does this in App Store Connect and on the server. Do not commit the API key. This repo does not create the products.

The iOS app sells three auto-renewable subscriptions in one subscription group. Android and web stay on Stripe. Apply `supabase/migrations/047_apple_billing_source.sql` and set the environment variables below before the backend that verifies purchases is deployed.

## 1. Agreements, tax, and banking

1. App Store Connect → Agreements, Tax, and Banking.
2. Sign the Paid Apps agreement.
3. Add the bank account and tax forms. In-App Purchases stay unavailable until this is complete.

## 2. Small Business Program

App Store Connect → Agreements, Tax, and Banking → Small Business Program. Enroll if EchoDesk is under the program's revenue limit so the commission is 15% instead of 30%.

## 3. App and In-App Purchase capability

- Bundle ID: `com.echodesk.echodeskMobile`
- Xcode → Runner target → Signing & Capabilities → add In-App Purchase.
- The capability does not add a new entitlements key. StoreKit is enabled by the capability on the App ID.

## 4. Subscription group and products

Create one subscription group, suggested name **EchoDesk**. Put all three products in that group so an upgrade replaces the current plan instead of charging a second subscription. In App Store Connect, level 1 is the highest tier: an upgrade takes effect immediately and a downgrade waits until renewal.

| Reference name | Product ID | Duration | Included | Suggested price (US) | Group level |
|----------------|------------|----------|----------|----------------------|-------------|
| Business Monthly | `com.echodesk.sub.business.monthly` | 1 month | 1,500 minutes | $249.99 | 1 |
| Growth Monthly | `com.echodesk.sub.growth.monthly` | 1 month | 750 minutes | $149.99 | 2 |
| Starter Monthly | `com.echodesk.sub.starter.monthly` | 1 month | 250 minutes | $69.99 | 3 |

Localization (English, U.S.) for each product:

- Display name: Starter, Growth, or Business.
- Description: the minute allowance above, monthly auto-renewable subscription for the AI receptionist. Do not mention buying on echodesk.us.

Set the prices in App Store Connect. The app reads the localized price from StoreKit and does not ship these dollar amounts. If you change a product id, set the same value in `APPLE_IAP_PRODUCT_STARTER` / `GROWTH` / `BUSINESS` on the server and in the iOS `--dart-define` flags.

The hidden `dev_test` plan stays debug-only and is not an App Store product.

## 5. App Store Server Notifications

App Store Connect → the app → App Information → App Store Server Notifications (Version 2).

Set both Production and Sandbox URLs to:

`https://echodesk.us/api/apple/notifications`

The backend verifies the signed JWS. It updates renewals, expirations, refunds, revocations, and billing grace. A Test notification from App Store Connect should return success once the environment variables are set.

## 6. In-App Purchase API key

App Store Connect → Users and Access → Integrations → In-App Purchase → Generate API Key.

Copy:

- Issuer ID → `APPLE_ISSUER_ID`
- Key ID → `APPLE_KEY_ID`
- The `.p8` file, downloaded once → `APPLE_PRIVATE_KEY` (PEM text, newlines as `\n`) or `APPLE_PRIVATE_KEY_PATH` on the server

Also set:

- `APPLE_BUNDLE_ID=com.echodesk.echodeskMobile`
- `APPLE_IAP_ENVIRONMENT=sandbox` for TestFlight and review, then `production` for the live store. One URL can verify both; Production verification also needs `APPLE_APP_APPLE_ID` (the numeric Apple ID of the app).
- Leave `APPLE_IAP_ALLOW_XCODE` unset on the server.

The full list is in `docs/core/ENV.md` and `backend/.env.example`.

## 7. Sandbox tester

Users and Access → Sandbox → Testers. Create a sandbox Apple ID. On the iPhone, sign into Media & Purchases with that sandbox account only when the purchase sheet asks. Do not sign the whole phone into the sandbox Apple ID.

## 8. Review screenshot and notes

1. Archive build `1.0.0` (4) with `PURCHASES_ENABLED=true`. See `BETA_BUILD.md`.
2. On a sandbox purchase, capture the plans screen showing the plan name, 1 month duration, the App Store price, included minutes, auto-renewal text, Terms, Privacy, and Restore Purchases.
3. Attach that screenshot to each subscription in App Store Connect (the review screenshot required for subscriptions).
4. Paste `APP_REVIEW_NOTES.md` into App Review Information → Notes. It describes in-app subscriptions. Do not describe the app as a companion app.

## Server order

1. Apply migration 047.
2. Set the Apple environment variables.
3. Deploy the backend.
4. Upload the iOS build.

Until those are done, the paywall can load StoreKit products but the account will not activate.
