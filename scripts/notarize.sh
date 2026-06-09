#!/usr/bin/env bash
#
# Build, Developer ID-sign, notarize, and staple NetCatch for warning-free
# distribution. REQUIRES an Apple Developer Program account — see docs/NOTARIZATION.md.
#
# Usage:
#   TEAM_ID=ABCDE12345 ./scripts/notarize.sh
#
# Environment:
#   TEAM_ID        (required) your 10-char Apple Developer Team ID
#   SIGN_ID        (optional) signing identity; default "Developer ID Application"
#   NOTARY_PROFILE (optional) notarytool keychain profile; default "netcatch-notary"
#                  Create once with:  xcrun notarytool store-credentials
#
set -euo pipefail

: "${TEAM_ID:?Set TEAM_ID to your Apple Developer Team ID (see docs/NOTARIZATION.md)}"
SIGN_ID="${SIGN_ID:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-netcatch-notary}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/notarize"
APP="$BUILD/Build/Products/Release/NetCatch.app"

echo "==> Building + signing (Developer ID, hardened runtime)…"
xcodebuild -project "$ROOT/NetCatch.xcodeproj" -scheme NetCatch -configuration Release \
  -derivedDataPath "$BUILD" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean build

echo "==> Verifying code signature…"
codesign --verify --strict --verbose=2 "$APP"

VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
SUBMIT_ZIP="$BUILD/NetCatch-submit.zip"
echo "==> Zipping for submission…"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> Submitting to Apple notary service (a few minutes)…"
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket to the app…"
xcrun stapler staple "$APP"

OUT="$ROOT/NetCatch-${VER}.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"

echo "==> Gatekeeper assessment:"
spctl -a -vvv -t install "$APP" || true

echo ""
echo "✅ Notarized + stapled: $OUT"
echo "   Attach it to a release, e.g.:  gh release upload v${VER} \"$OUT\""
