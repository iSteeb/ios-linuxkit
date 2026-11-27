# TestFlight release pipeline

`release*` tags push a build to the external TestFlight group end-to-end:
archive → checks → export → altool validate + upload → wait for processing →
"What to Test" notes → add to the `External` group → submit for Beta App
Review. Everything runs on the GitHub-hosted macOS runner; no Apple ID
session is required (signing is manual, uploads use the App Store Connect
API key).

```
git tag release-1.0.0 && git push origin release-1.0.0
```

A `release-X.Y.Z` tag overrides the app version; plain `release*` tags keep
the project's MARKETING_VERSION. The build number is `github.run_number`
(always increasing).

## One-time repository setup (already done, recorded here)

- environment `testflight` on the repo (referenced by
  `.github/workflows/testflight.yml`)
- secrets: `DIST_P12_BASE64`, `DIST_P12_PASSWORD`, `APPSTORE_PROFILE_BASE64`,
  `ASC_KEY_P8`
- variables: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `TESTFLIGHT_GROUP` (`External`)

## Where the signing material comes from

- **ASC API key** (`FWTD9927FA`): App Store Connect → Users and Access →
  Integrations. The `.p8` content is the `ASC_KEY_P8` secret; it also lives
  at `~/.appstoreconnect/private_keys/AuthKey_FWTD9927FA.p8` on the dev Mac
  for local `altool`/API use.
- **Apple Distribution identity**: generated via the ASC API (CSR +
  `POST /v1/certificates`), private key on the dev Mac. The P12 export
  (key + cert) is the `DIST_P12_*` secrets. Re-export with:
  `openssl pkcs12 -export -inkey dist.key -in dist.pem …`
- **App Store profile**: `termulator App Store`
  (`POST /v1/profiles`, bound to `dev.isteeb.linuxkit` and the distribution
  cert), base64 in `APPSTORE_PROFILE_BASE64`. Regenerate after a year or
  when the distribution cert is replaced.

`Distribution/release-testflight.sh` validates the profile (team, bundle id,
App Store type, expiry, contains the P12 cert) before using it, so a wrong
or expired secret fails early with a clear message.

## Local dry run

Everything except the keychain juggling can be reproduced locally:

```
xcrun altool --validate-app -f <ipa> -t ios --apiKey FWTD9927FA \
  --apiIssuer c93c0481-0518-4ec3-b19e-b235260c0f91
```

`Distribution/asc_testflight.py` also works locally with
`ASC_KEY_ID`/`ASC_ISSUER_ID`/`ASC_KEY_P8` in the environment — useful for
checking build state and pushing a build to the group without a release tag.

## Review posture

The app's compliance answer is baked in (`ITSAppUsesNonExemptEncryption` is
`false` in app/Info.plist), so builds never sit in "Missing Compliance
Information". Beta App Review sees the wording in the Beta App Description;
see the notes in `CONTINUITY.md` for the 2.5.2 framing (terminal emulator
with a built-in interpreter — the iSH Shell / a-Shell precedent).
