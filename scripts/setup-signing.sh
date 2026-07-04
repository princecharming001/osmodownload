#!/bin/bash
# Create a STABLE self-signed code-signing identity ("Osmo Dev Signing") once, so
# macOS keeps the app's TCC grants (Full Disk Access, Accessibility) and Keychain
# ACLs across rebuilds. Ad-hoc signing ("-") changes the code hash every build, so
# every permission resets and the user is re-prompted constantly. Idempotent.
set -euo pipefail
NAME="Osmo Dev Signing"

if security find-certificate -c "$NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "✓ '$NAME' already exists"; exit 0
fi

TMP=$(mktemp -d)
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:osmo -name "$NAME"
# -A: allow all apps (incl. codesign) to use the key without an access prompt.
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P osmo -A
rm -rf "$TMP"
echo "✓ created '$NAME' — builds will now sign stably"
