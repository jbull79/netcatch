#!/bin/bash
#
# Sign a NetCatch.app with a STABLE, self-signed local certificate.
#
# Why: with ad-hoc signing, the app's designated requirement is a cdhash that
# changes on every build, so macOS TCC treats each rebuild as a new app and the
# Accessibility / Input Monitoring permissions reset to "not granted". Signing
# with a fixed certificate gives a stable requirement
# (`identifier "com.netcatch.NetCatch" and certificate leaf = H"<hash>"`), so a
# permission granted once persists across rebuilds.
#
# The certificate is created locally on first run (no Apple Developer account
# needed). It is NOT trusted by Gatekeeper — that only affects the "unidentified
# developer" prompt on downloaded copies, not signing or TCC.
#
# Usage: scripts/sign-local.sh /path/to/NetCatch.app
set -euo pipefail

APP="${1:?usage: sign-local.sh <path-to-.app>}"
CERT_NAME="NetCatch Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
ENTITLEMENTS="$(cd "$(dirname "$0")/.." && pwd)/NetCatch/NetCatch.entitlements"

if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Creating local signing certificate '$CERT_NAME'…"
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=v3
[dn]
CN=$CERT_NAME
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
  # Import cert + key separately — a LibreSSL-generated PKCS12 fails macOS's
  # `security import` (MAC verification), so we avoid the .p12 path.
  openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
  openssl req -x509 -new -key "$TMP/key.pem" -days 3650 -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
  security import "$TMP/cert.pem" -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null
  security import "$TMP/key.pem"  -k "$KEYCHAIN" -A -T /usr/bin/codesign >/dev/null
  rm -rf "$TMP"
fi

codesign --force --deep --sign "$CERT_NAME" --entitlements "$ENTITLEMENTS" "$APP"
echo "Signed: $APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true
