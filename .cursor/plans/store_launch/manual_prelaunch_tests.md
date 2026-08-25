# EchoDesk pre-launch manual tests

Run these on a **real phone**, release build, against **production** (`https://echodesk.us`).

Check a box only if you saw it yourself. If something fails, fix it before store submit.

Voice clone / “Use my voice” is **paused**. Do not test it. Do not file it as a launch blocker.

---

## How to use this file

1. Use a **new email** you have not used on EchoDesk (or a fresh test account).
2. Have a **second phone** to call the business number.
3. Walk the list in order. The last section is the “stranger” test after the stores go live.

---

## A. New customer path

- [ ] I can create an account with a new email in the app (not on the website).
- [ ] The confirmation email arrives. After I tap the link, I land back in the app (or I can log in with the same email).
- [ ] I can start the **14-day trial** (or pay Starter if I skip trial).
- [ ] Settings → Billing shows the trial or paid plan. No leftover “dev” or test plan names.
- [ ] I can connect **Google Calendar**.
- [ ] I can create a receptionist: pick a **professional voice**, get a US business number.
- [ ] Step 5 does **not** show “Use my voice”.
- [ ] The create-phone step does **not** say Telnyx or other carrier jargon.
- [ ] SMS and WhatsApp still say **Coming soon**.
- [ ] Settings → Account has **Delete account**. Confirming it signs me out and I cannot log in with that email.

## B. Live call

- [ ] I call the business number from another phone.
- [ ] The recording notice and greeting start right away (first second).
- [ ] I can book an appointment. If I do not name a service, the booking appears under **Appointments → Needs review**.
- [ ] The call shows up in call history.
- [ ] Minutes / usage go up after the call.

## C. Delete and leftover numbers

- [ ] When I delete a receptionist, I see: the number will be fully released in **24–48 hours**.
- [ ] The app does not leave me stuck unable to get a new number because of old “release pending” holds.

## D. Website (after Phase 3 copy is live)

- [ ] echodesk.us does **not** tell anyone to run `./run_prod.sh` or clone a repo.
- [ ] Get started says: download the app, create the account **in the app**.
- [ ] Buttons are App Store + Play (or “listing soon” + email until the stores approve).
- [ ] Privacy, Terms, and support email (`echodesk2@gmail.com`) still work.
- [ ] The site does **not** mention voice clone or “use your own voice”.

## E. After the stores are live (stranger test)

Use a phone that **never** had a test install from a computer.

- [ ] Install from the App Store or Play Store (not from a Mac/PC).
- [ ] Create account → trial or paid → calendar → receptionist → inbound call works.
- [ ] Website store buttons open the real listings.
- [ ] A new trial claim reduces the “first 100” counter.
- [ ] An email to `echodesk2@gmail.com` arrives.

---

## Not required for launch

- First-reply delay / “a bit slow to talk”
- Voice clone quality or “Use my voice”
- Website account creation
- SMS / WhatsApp actually sending
- A web version of the product
