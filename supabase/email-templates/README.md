# Auth email templates

Hosted Supabase Auth (not the VPS) sends confirm / reset mail through Resend.

The confirmation HTML lives here so we can version it. Production is updated in
**Supabase Dashboard → Authentication → Email Templates → Confirm signup**.

Paste `confirmation.html` into the body field. Subject: `Confirm your EchoDesk account`.

The logo is a public PNG on the marketing site:

`https://echodesk.us/images/echodesk-logo-mark.png`

A smaller `landing/public/images/echodesk-email-mark.png` is ready for the next landing deploy.

Gmail’s orange “E” circle next to the sender is **not** this template. That avatar
comes from Gmail’s fallback for `EchoDesk <noreply@echodesk.us>`. Changing it
needs a profile photo / BIMI on the sending domain, not this HTML.
