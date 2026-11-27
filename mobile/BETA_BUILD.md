# Internal Beta Build Guide

Instructions for building and distributing the Echodesk mobile app for internal testing.

## Prerequisites

- Flutter SDK 3.2+
- For Android: Java 17 or 21, Android SDK. The project uses Gradle 8.11.1 and AGP 8.9.1 (Java 21 compatible). If you see "Unsupported class file major version 65", the Gradle wrapper has been updated to fix this.
- For iOS: Xcode, Apple Developer account (for TestFlight)
- Backend deployed and reachable (e.g. `https://echodesk.us`)

## Env for Production Builds

Use your production API and Supabase values:

```bash
API_BASE_URL=https://echodesk.us
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=your_anon_key
```

## Android: Build Release APK

1. **Build the APK** (unsigned, for local/testing):

```bash
cd mobile
flutter pub get
flutter build apk --release \
  --dart-define=API_BASE_URL=https://echodesk.us \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

2. **Distribute**: Share the APK via email, link, or internal file server. Testers enable "Install from unknown sources" on Android.

3. **For Play Store** (later): Create a keystore, configure `android/key.properties` and `android/app/build.gradle` for signing, then use `flutter build appbundle`.

## iOS: Build for TestFlight

1. **Open in Xcode** and configure signing:

```bash
cd mobile
open ios/Runner.xcworkspace
```

- Select Runner target → Signing & Capabilities
- Choose your Team and provisioning profile
- Ensure Bundle ID matches your App Store Connect app

2. **Build and archive** (App Store / TestFlight). iOS is a sign-in companion:
   purchases stay off so plan, price, trial, and checkout UI is stripped.

```bash
flutter build ipa --release --build-number=3 \
  --dart-define=PURCHASES_ENABLED=false \
  --dart-define=API_BASE_URL=https://echodesk.us \
  --dart-define=SUPABASE_URL=$SUPABASE_URL \
  --dart-define=SUPABASE_ANON_KEY=$SUPABASE_ANON_KEY
```

Current store build: version `1.0.0`, build number `3` (`pubspec.yaml` `1.0.0+3`).

Output: `build/ios/ipa/*.ipa`

3. **Upload to TestFlight**:

- Open Xcode → Window → Organizer
- Select the archive → Distribute App → App Store Connect → Upload
- Or use: `xcrun altool --upload-app -f build/ios/ipa/*.ipa -t ios -u YOUR_APPLE_ID -p APP_SPECIFIC_PASSWORD`

4. **Add internal testers** in App Store Connect → Your App → TestFlight → Internal Testing.

## Validation Checklist

Before sharing with testers, run through the full flow:

| Step | Action | Expected |
|------|--------|----------|
| 1 | Open app → Get Started | Sign up screen |
| 2 | Sign up with email | Account created, redirect to dashboard |
| 3 | Android/web: dashboard shows "Upgrade" if not subscribed. iOS store build (`PURCHASES_ENABLED=false`): inactive account shows "Your account isn't active yet. Contact echodesk2@gmail.com." with no purchase button | No prices, plans, trials, or buy buttons on iOS |
| 4 | Android/web: tap Subscribe → complete Stripe Checkout. Skip on the iOS store build | Redirect back to the app on Android/web; iOS never opens checkout |
| 5 | Finish onboarding: Connect Calendar, create receptionist, confirm business line | Onboarding complete |
| 6 | Create receptionist (wizard) | Receptionist created and attached to the business line |
| 7 | Receptionist detail → Start outbound call | Call initiated, "Call initiated" snackbar |
| 8 | Dashboard → Minutes this period | Shows usage (e.g. 0 / 300) |
| 9 | Android/web: Settings → Billing opens the Stripe portal. iOS store build has no Billing section | Privacy Policy and Terms are in Settings on every platform |
| 10 | Help (from dashboard) | Help screen with guides |

## Run Script

For quick local runs with env from project root:

```bash
./run.sh          # macOS
./run.sh chrome   # Chrome
```

Requires `../.env.local` with `NEXT_PUBLIC_APP_URL`, `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
