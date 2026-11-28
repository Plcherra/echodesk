# Apple root certificates

Public roots used to verify App Store Server API and App Store Server Notifications V2 JWS signatures. These are not secrets.

Downloaded from Apple's certificate authority:

- `AppleIncRootCertificate.cer` — https://www.apple.com/appleca/AppleIncRootCertificate.cer
- `AppleRootCA-G2.cer` — https://www.apple.com/certificateauthority/AppleRootCA-G2.cer
- `AppleRootCA-G3.cer` — https://www.apple.com/certificateauthority/AppleRootCA-G3.cer

App Store Server notifications chain to Apple Root CA - G3. The older roots are included so a chain that still anchors there can verify. Override the directory with `APPLE_ROOT_CA_PATH` if Apple publishes a newer root.
