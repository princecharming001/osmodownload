#!/bin/bash
# publish-appcast.sh — turn a notarized Osmo zip into a Sparkle OTA release.
# Run this AFTER scripts/release.sh has produced a notarized, stapled zip.
#
# It: (1) stages the zip under a version-named file, (2) runs Sparkle's
# generate_appcast (which EdDSA-signs each build with the private key in your
# login Keychain and writes appcast.xml), pointing the download URL at the
# GitHub Release that will host the zip, and (3) copies appcast.xml into the
# leftonread site repo so it serves at https://leftonread.in/appcast.xml.
#
# You still do two manual, side-effecting steps yourself (they need approval):
#   • gh release create/upload the zip to princecharming001/leftonread
#   • git commit + push the leftonread repo (appcast.xml)
# This script prints the exact commands for both at the end.
#
#   Usage:  ./scripts/publish-appcast.sh 0.2.1 [path-to-notarized.zip]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: publish-appcast.sh <version> [zip]}"
SRC_ZIP="${2:-.build/release/Osmo-notarized.zip}"
[ -f "$SRC_ZIP" ] || { echo "✗ notarized zip not found: $SRC_ZIP (run scripts/release.sh first)"; exit 1; }

REPO="princecharming001/leftonread"
TAG="v${VERSION}"
# CI overrides this to a fresh checkout of the leftonread repo; locally it's the
# working copy on disk.
SITE_REPO="${OSMO_SITE_REPO:-/Users/home/URAP - Lead - Levine/leftonread}"
DL_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

# Locate Sparkle's generate_appcast (built into the SPM artifacts).
GA="$(/usr/bin/find .build -type f -name generate_appcast -perm +111 2>/dev/null | head -1)"
[ -n "$GA" ] || { echo "✗ generate_appcast not found under .build (build the app once so SPM fetches Sparkle)"; exit 1; }

STAGE=".build/appcast"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ZIP_NAME="Osmo-${VERSION}.zip"
cp "$SRC_ZIP" "$STAGE/$ZIP_NAME"

echo "→ generating + EdDSA-signing appcast (download base: $DL_PREFIX)…"
# Locally the EdDSA private key comes from the login Keychain. In CI there's no
# Keychain entry, so SPARKLE_ED_KEY_FILE points at a file holding the private key.
if [ -n "${SPARKLE_ED_KEY_FILE:-}" ]; then
  "$GA" --ed-key-file "$SPARKLE_ED_KEY_FILE" --download-url-prefix "$DL_PREFIX" "$STAGE"
else
  "$GA" --download-url-prefix "$DL_PREFIX" "$STAGE"
fi
[ -f "$STAGE/appcast.xml" ] || { echo "✗ generate_appcast did not produce appcast.xml"; exit 1; }

cp "$STAGE/appcast.xml" "$SITE_REPO/appcast.xml"
echo "✓ appcast.xml written to the site repo. Enclosure:"
grep -o 'url="[^"]*"' "$SITE_REPO/appcast.xml" | sed 's/^/    /'
grep -o 'sparkle:edSignature="[^"]*"' "$SITE_REPO/appcast.xml" | sed 's/^/    /'

cat <<EOF

Next (side-effecting — do with approval):
  1. Publish the update zip to the GitHub Release:
       gh release create $TAG "$STAGE/$ZIP_NAME" --repo $REPO \\
         --title "Osmo $VERSION" --notes "Auto-update release" --latest
     (or, if the tag exists:  gh release upload $TAG "$STAGE/$ZIP_NAME" --repo $REPO --clobber)
  2. Commit + push the appcast so leftonread.in/appcast.xml updates:
       cd "$SITE_REPO" && git add appcast.xml && git commit -m "OTA: Osmo $VERSION appcast" && git push
EOF
