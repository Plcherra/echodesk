# Store listing draft (do not submit)

Voices at launch: **five professional presets only**. Do not mention clone, “use my voice”, or replacing Google TTS. SMS / WhatsApp stay Coming soon.

**Privacy policy:** https://echodesk.us/privacy  
**Support:** echodesk2@gmail.com  
**Version in repo:** leave `mobile/pubspec.yaml` at `1.0.0+1` until the owner starts a signed build (unsure whether anyone is mid-build).

## Short description (Play / App Store subtitle)

AI receptionist that answers calls and books from your Google Calendar.

## Full description

EchoDesk is an AI receptionist for appointment-based businesses. It answers the phone when you are busy, closed, or with a customer, checks real Google Calendar availability, and books appointments for you.

In the app you can:

- Create an account and start a 14-day trial (60 minutes, first 100 customers) or choose Starter, Growth, or Business
- Connect Google Calendar
- Create a receptionist and pick one of five professional voices
- Get a US business number
- Review calls, recordings, summaries, and appointments on your phone

EchoDesk does not offer a web signup form. Create your account in the app.

SMS and WhatsApp are coming soon.

Questions: echodesk2@gmail.com

## Voice copy (use this, nothing else)

Choose from five professional voices: Friendly & Warm, Professional & Calm, Premium Concierge, Energetic & Upbeat, and Confident & Clear. Preview them in the app before you go live.

Do **not** say: use your own voice, clone, record your voice, Pocket, or that we replaced Google TTS.

## Privacy / data safety (match the app)

While clone is paused, the microphone is **not** required for the launch path.

Collects / uses:

- Account: email, password (Supabase Auth)
- Calendar: Google Calendar read/write for availability and bookings
- Phone calls: business number, call recordings, transcripts/summaries, usage minutes
- Payments: Stripe subscriptions and trial
- Support: optional email to echodesk2@gmail.com

Does not collect (at launch): voice-clone samples, contacts list, precise location.

## Identifiers

- Android: `com.echodesk.mobile`
- iOS: `com.echodesk.echodeskMobile` (Xcode); Firebase iOS plist also lists `com.echodesk.mobile` — confirm the App Store Connect bundle ID before upload
- Checkout return: `echodesk://checkout`
- Email confirm return: `echodesk://auth-callback`

## Owner still does

- Play upload keystore (never commit)
- Signed AAB / IPA with `API_BASE_URL=https://echodesk.us`
- Screenshots
- Submit (Phase 7 only)
