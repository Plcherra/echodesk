# App Review notes (paste into App Store Connect)

EchoDesk is an AI receptionist for appointment-based businesses. Account creation and subscription purchase both happen inside the iOS app. This is not a companion app and there is no link to buy a subscription on the website.

Auto-renewable subscriptions, one subscription group, billed monthly by Apple:

- Starter — `com.echodesk.sub.starter.monthly` — 250 minutes per month
- Growth — `com.echodesk.sub.growth.monthly` — 750 minutes per month
- Business — `com.echodesk.sub.business.monthly` — 1,500 minutes per month

The paywall shows the localized price from StoreKit, the plan name, the 1-month duration, what is included, the auto-renewal terms, Terms of Use (https://echodesk.us/terms.html), Privacy Policy (https://echodesk.us/privacy.html), and Restore Purchases. Settings → Manage subscription opens Apple's subscription management.

How to review:

1. Open the app and tap Create account. Confirm the email if asked, then sign in. Creating an account does not open a website checkout.
2. An account with no active plan is shown the plans screen. Purchase any plan with the sandbox Apple ID attached to this review.
3. The subscription is tied to that EchoDesk account. After it activates, the app continues to calendar setup and creating a receptionist.
4. Settings → Manage subscription opens the App Store subscription page. Restore Purchases is on the plans screen.
5. An account that already has an active subscription, including one purchased outside the App Store, can sign in and use the app with no paywall.

Included minutes on an Apple subscription are a hard cap. The app does not sell extra minutes and does not link to another payment method.

A live phone call is not required to review subscriptions. The receptionist answers on a business number only after setup is finished.

Sandbox: use the sandbox tester created for this app. Do not use a production Apple ID.
