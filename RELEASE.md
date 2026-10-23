# Releases

How a version of the app is built, signed and published. The workflow
[`.github/workflows/release.yml`](.github/workflows/release.yml) does the work; this page lists what
it needs and what to check.

## One-time setup

In the GitHub repository under *Settings › Secrets and variables › Actions*:

| Name | Kind | Content |
|---|---|---|
| `APPLE_TEAM_ID` | variable | Team ID of the Apple developer account (ten characters) |
| `MACOS_CERTIFICATE_P12` | secret | certificate *Developer ID Application* with its private key, exported from Keychain Access as `.p12`, then Base64: `base64 -i certificate.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | secret | password chosen for the `.p12` export |
| `NOTARY_API_KEY_P8` | secret | content of the App Store Connect API key `AuthKey_….p8` (*Users and Access › Integrations › Team Keys*, role *Developer*) |
| `NOTARY_API_KEY_ID` | secret | key ID of that API key |
| `NOTARY_API_ISSUER_ID` | secret | issuer ID shown above the list of team keys |
| `SPARKLE_ED_PRIVATE_KEY` | secret | private key that signs updates (see below) |

Instead of the API key, notarization also works with an Apple Account: secrets `NOTARY_APPLE_ID`
and `NOTARY_PASSWORD` (an app-specific password from account.apple.com).

Only the account holder can create a *Developer ID Application* certificate. Keep the `.p12`, its
password and the Sparkle key in the company password manager; GitHub secrets cannot be read back.
The project's certificate (Developer ID G2, valid until 2027-11-22) is in the maintainer's login
keychain; export the `.p12` from Keychain Access. A `.p12` written by OpenSSL 3 or later needs
`-legacy`, otherwise `security import` rejects it; macOS's own `/usr/bin/openssl` works as is.

### Sparkle signing key

Every update is signed with an EdDSA key; installed apps only accept updates that match the
public key in their `Info.plist` (build setting `SPARKLE_PUBLIC_KEY`). The private key was
generated with Sparkle's `generate_keys` and lives in the maintainer's login keychain under the
account `zeiterfassung-fuer-odoo`. To store it as a secret:

```bash
generate_keys --account zeiterfassung-fuer-odoo -x sparkle-key.txt
gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle-key.txt
rm sparkle-key.txt
```

`generate_keys` is in the `bin` folder of the
[Sparkle release](https://github.com/sparkle-project/Sparkle/releases) used by the project. If the
private key is lost, existing installations can no longer be updated automatically; users would
have to install the next version from the DMG by hand.

## Publishing a version

1. **Code on `main`:** all changes merged; `CHANGELOG.md` has a section `## <version> – <date>`.
   Its text becomes the release notes on GitHub and in the update window of the app.
2. **Checks before tagging:**
   - unit tests: `xcodebuild test -project Zeiterfassung.xcodeproj -scheme Zeiterfassung -destination 'platform=macOS'`;
   - live tests against a fresh test database from `dev/start-test-odoo.sh` with the keys of
     all three test users (`TEST_RUNNER_ZEITERFASSUNG_LIVE_URL`, `…_KEY`, `…_LOGIN`, `…_DB`);
   - a short manual run of the built app: sign in, book an entry, check in and out, switch the
     functions in the settings.
3. **No real data:** the repository contains invented names only; screenshots come from
   `-renderScreenshots` with the built-in demo data.
4. **Tag:** `git tag -a v<version> -m "Zeiterfassung für Odoo <version>"` and
   `git push origin v<version>`. The version comes from the tag; the project does not need to be
   changed.
5. **Workflow:** runs the tests, builds the app for Apple Silicon and Intel, signs it with the
   Developer ID, has app and DMG notarized by Apple, signs the DMG for Sparkle, checks that the
   signature matches the public key in the app, and creates the GitHub release with the DMG and
   `appcast.xml`.
6. **Afterwards:** download the DMG, install it on a Mac that has not seen the app, and check that
   an installed older version offers the update (*Nach Updates suchen …*).

A run started by hand (*Actions › Release › Run workflow*) builds a test DMG as workflow artifact
without publishing anything; without the certificate secrets it is not signed.

## Testing the update path locally

The whole way from version list to relaunch can be tested on one Mac without touching the
installed app, with a separate bundle ID and a throwaway key:

1. Create an Ed25519 key pair (for example with CryptoKit) and write the raw private key as Base64
   to a file.
2. Build two Debug versions, for example 0.9.0 and 0.9.1, with
   `PRODUCT_BUNDLE_IDENTIFIER=de.bm1.ZeiterfassungFuerOdoo.updatetest`,
   `SPARKLE_FEED_URL=http://127.0.0.1:8765/appcast.xml` and `SPARKLE_PUBLIC_KEY=<test public key>`.
3. Make a DMG of 0.9.1 with `scripts/make-dmg.sh`, then the version list with
   `SPARKLE_KEY_FILE=<key file> DOWNLOAD_URL_PREFIX=http://127.0.0.1:8765/ scripts/make-appcast.sh`,
   and check it with `scripts/verify-update.swift`.
4. Serve `build/appcast` with `python3 -m http.server 8765 --bind 127.0.0.1`.
5. Start 0.9.0 with `open Zeiterfassung.app --args -updateSelfTest YES`: it finds 0.9.1,
   downloads and installs it, and Sparkle relaunches the app as 0.9.1 within a few seconds.

The development status is _Alpha_ until the app has been used daily for half a year, _Beta_
after that.
