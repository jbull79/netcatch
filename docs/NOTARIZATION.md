# Notarizing NetCatch

Notarization is what removes the *"Apple could not verify … is free from malware"*
Gatekeeper warning, so the app opens with a normal double-click on any unmanaged Mac.

> **Prerequisite (no free path):** notarization requires enrollment in the
> **Apple Developer Program** (US $99 / year). Apple only issues the required
> **Developer ID Application** certificate to paid members — there is no way to notarize
> with a free Apple ID. (Note: a strict corporate/MDM-managed Mac may still block the app
> even when notarized; only IT can whitelist it there.)

Once enrolled, the whole flow is a single command: [`scripts/notarize.sh`](../scripts/notarize.sh).

## One-time setup

1. **Enroll** in the Apple Developer Program at <https://developer.apple.com/programs/>.

2. **Create a "Developer ID Application" certificate** and install it in your login
   keychain (Xcode → Settings → Accounts → Manage Certificates → ＋, or the developer
   portal). Note your **Team ID** (10 characters) from the Membership page.

3. **Store notarization credentials** once, in the keychain, so the script can submit
   non-interactively. Easiest is an app-specific password:
   - Create one at <https://appleid.apple.com> → Sign-In and Security → App-Specific Passwords.
   - Then:
     ```sh
     xcrun notarytool store-credentials netcatch-notary \
       --apple-id "you@example.com" \
       --team-id  "ABCDE12345" \
       --password "abcd-efgh-ijkl-mnop"   # the app-specific password
     ```
   (Alternatively use an App Store Connect API key with `--key/--key-id/--issuer`.)

## Building a notarized release

```sh
TEAM_ID=ABCDE12345 ./scripts/notarize.sh
```

This builds a Release with **hardened runtime**, signs it with your Developer ID,
submits it to Apple's notary service, waits for the result, **staples** the ticket to
the app, and writes `NetCatch-<version>.zip` at the repo root. It also runs
`spctl -a -t install` so you can confirm Gatekeeper now accepts it.

Then attach it to the matching release:

```sh
gh release upload v1.1.0 NetCatch-1.1.0.zip --clobber
```

## What the project currently uses

The Xcode project is configured for **ad-hoc** signing (`CODE_SIGN_IDENTITY = "-"`,
no team) so anyone can build and run locally without an account. The notarize script
**overrides** those settings at build time (Developer ID + hardened runtime) rather than
changing the project, so day-to-day ad-hoc builds keep working unchanged.

## Optional: notarize in CI (GitHub Actions)

Store these repository **secrets** and run the script on a `macos-latest` runner:

- `DEVELOPER_ID_CERT_P12` (base64 of the exported `.p12`) and `CERT_PASSWORD`
- `TEAM_ID`
- notarytool credentials (`APPLE_ID`, `APPLE_APP_PASSWORD`, or an API key)

The runner imports the cert into a temporary keychain, then runs
`TEAM_ID=… ./scripts/notarize.sh` and uploads the stapled zip to the release. (Ask and
this workflow can be added once an account exists.)
