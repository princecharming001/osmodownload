#!/bin/bash
# publish-ota.sh — ship an Osmo auto-update in ONE command.
#
# Wraps the whole OTA pipeline:
#   1. build + Developer-ID sign + notarize + staple      (scripts/release.sh)
#   2. zip the notarized app as Osmo-<version>.zip
#   3. generate_appcast → sign the enclosure with the EdDSA key (from keychain)
#   4. create/replace GitHub release v<version> with the zip
#   5. copy appcast.xml into the leftonread site repo → commit → push
#      (GitHub Pages serves it at https://leftonread.in/appcast.xml, the feed
#       every installed Osmo polls — so the update just appears in the app)
#
# Every installed 0.2.1+ build has the real SUPublicEDKey + this feed URL baked
# in, so from here on a user's app auto-downloads & installs each new version.
#
# Prereqs (all already present on Anish's Mac — see memory osmo-notarization):
#   - EdDSA private key in login keychain (svce=https://sparkle-project.org)
#   - Developer ID Application cert + App Store Connect notary key
#   - gh authed for princecharming001/leftonread
#
# Usage:
#   1. bump MARKETING_VERSION (+ CURRENT_PROJECT_VERSION) in project.yml
#   2. ./scripts/publish-ota.sh
#
# Env (sensible defaults for this Mac; override if creds move):
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "✗ $1" >&2; exit 1; }

export OSMO_TEAM_ID="${OSMO_TEAM_ID:-3TJ8RC3JCX}"
export OSMO_SIGN_IDENTITY="${OSMO_SIGN_IDENTITY:-Developer ID Application: Anish Polakala (3TJ8RC3JCX)}"
export OSMO_NOTARY_KEY_ID="${OSMO_NOTARY_KEY_ID:-422MKHNWD5}"
export OSMO_NOTARY_ISSUER="${OSMO_NOTARY_ISSUER:-c4c8d671-d14d-48b8-a605-94c23a63b2fa}"
export OSMO_NOTARY_KEY_PATH="${OSMO_NOTARY_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_422MKHNWD5.p8}"

SITE_REPO="${OSMO_SITE_REPO:-/Users/home/URAP - Lead - Levine/leftonread}"
GH_REPO="${OSMO_GH_REPO:-princecharming001/leftonread}"
GENERATE_APPCAST=".build/xcode/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"

VERSION="${OSMO_VERSION:-$(grep -E 'MARKETING_VERSION' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
[ -n "$VERSION" ] || fail "could not resolve version from project.yml"
TAG="v$VERSION"
echo "▸ Publishing Osmo OTA update $TAG"

# ── 1. build + notarize + staple ───────────────────────────────────────────
echo "→ [1/5] build + notarize (scripts/release.sh)…"
./scripts/release.sh

APP=".build/release/Osmo.app"
[ -d "$APP" ] || fail "release.sh did not produce $APP"
xcrun stapler validate "$APP" >/dev/null 2>&1 || fail "app is not stapled — notarization incomplete"

# ── 2. versioned zip ───────────────────────────────────────────────────────
echo "→ [2/5] zipping Osmo-$VERSION.zip…"
STAGE=".build/appcast-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGE/Osmo-$VERSION.zip"

# ── 3. signed appcast (EdDSA key pulled from keychain automatically) ────────
echo "→ [3/5] generating signed appcast…"
[ -x "$GENERATE_APPCAST" ] || GENERATE_APPCAST="$(find .build -name generate_appcast -type f 2>/dev/null | head -1)"
[ -x "$GENERATE_APPCAST" ] || fail "generate_appcast tool not found under .build"
"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/$GH_REPO/releases/download/$TAG/" \
  "$STAGE"
grep -q "edSignature" "$STAGE/appcast.xml" || fail "appcast has no EdDSA signature — is the private key in the keychain?"

# ── 4. GitHub release with the zip ─────────────────────────────────────────
echo "→ [4/5] publishing GitHub release $TAG…"
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$STAGE/Osmo-$VERSION.zip" --repo "$GH_REPO" --clobber
else
  gh release create "$TAG" "$STAGE/Osmo-$VERSION.zip" --repo "$GH_REPO" \
    --title "Osmo $VERSION" \
    --notes "Notarized, Developer-ID signed. Auto-updates via Sparkle." --latest
fi
# verify the enclosure actually resolves before we advertise it
URL="https://github.com/$GH_REPO/releases/download/$TAG/Osmo-$VERSION.zip"
code="$(curl -sILo /dev/null -w '%{http_code}' "$URL")"
[ "$code" = "200" ] || fail "release asset $URL returned HTTP $code (not published?)"

# ── 5. publish the appcast on the site (this is the actual OTA push) ────────
echo "→ [5/5] publishing appcast to the site repo…"
cp "$STAGE/appcast.xml" "$SITE_REPO/appcast.xml"
git -C "$SITE_REPO" add appcast.xml
if git -C "$SITE_REPO" diff --cached --quiet; then
  echo "  (appcast unchanged — nothing to push)"
else
  git -C "$SITE_REPO" commit -q -m "OTA: Osmo $VERSION"
  git -C "$SITE_REPO" push origin HEAD
fi

echo ""
echo "✓ OTA $TAG published. Installed apps will pick it up on their next feed check"
echo "  (Sparkle checks automatically; users can also force it via Check for Updates)."
echo "  Feed: https://leftonread.in/appcast.xml"
