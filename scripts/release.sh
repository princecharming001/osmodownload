#!/bin/bash
# release.sh — build a DISTRIBUTABLE Osmo.app: Release config, Developer ID
# signing, Hardened Runtime, Apple notarization, and stapling. The stapled zip
# it produces opens on any Mac with NO "Apple could not verify" warning.
#
# This is the real fix for the Gatekeeper wall. It needs a paid Apple Developer
# account. Set these env vars (all required unless noted):
#
#   OSMO_TEAM_ID            Your 10-char Apple Team ID (Developer portal → Membership)
#   OSMO_SIGN_IDENTITY      The Developer ID cert name, e.g.
#                           "Developer ID Application: Your Name (TEAMID)".
#                           Install it once from developer.apple.com → Certificates
#                           into your login keychain (Xcode → Settings → Accounts
#                           → Manage Certificates → + → Developer ID Application).
#
# Notarization credentials — EITHER a saved notarytool keychain profile:
#   OSMO_NOTARY_PROFILE     Name you gave `xcrun notarytool store-credentials`
# OR an App Store Connect API key:
#   OSMO_NOTARY_KEY_ID, OSMO_NOTARY_ISSUER, OSMO_NOTARY_KEY_PATH   (.p8 file)
# OR an Apple ID app-specific password:
#   OSMO_APPLE_ID, OSMO_APPLE_PASSWORD   (app-specific pw from appleid.apple.com)
#
# Optional:
#   OSMO_VERSION            Marketing version to stamp (default: from project.yml)
#
# Usage:  OSMO_TEAM_ID=ABCDE12345 OSMO_SIGN_IDENTITY="Developer ID Application: …" \
#         OSMO_NOTARY_PROFILE=osmo  ./scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "✗ $1" >&2; exit 1; }
[ -n "${OSMO_TEAM_ID:-}" ]       || fail "OSMO_TEAM_ID is required (your Apple Team ID)."
[ -n "${OSMO_SIGN_IDENTITY:-}" ] || fail "OSMO_SIGN_IDENTITY is required (the Developer ID Application cert name)."

# Resolve which notarytool auth to use.
NOTARY_AUTH=()
if [ -n "${OSMO_NOTARY_PROFILE:-}" ]; then
  NOTARY_AUTH=(--keychain-profile "$OSMO_NOTARY_PROFILE")
elif [ -n "${OSMO_NOTARY_KEY_ID:-}" ] && [ -n "${OSMO_NOTARY_ISSUER:-}" ] && [ -n "${OSMO_NOTARY_KEY_PATH:-}" ]; then
  NOTARY_AUTH=(--key "$OSMO_NOTARY_KEY_PATH" --key-id "$OSMO_NOTARY_KEY_ID" --issuer "$OSMO_NOTARY_ISSUER")
elif [ -n "${OSMO_APPLE_ID:-}" ] && [ -n "${OSMO_APPLE_PASSWORD:-}" ]; then
  NOTARY_AUTH=(--apple-id "$OSMO_APPLE_ID" --password "$OSMO_APPLE_PASSWORD" --team-id "$OSMO_TEAM_ID")
else
  fail "No notarization credentials. Set OSMO_NOTARY_PROFILE, or the API-key trio, or OSMO_APPLE_ID + OSMO_APPLE_PASSWORD."
fi

OUT=".build/release"
APP="$OUT/Osmo.app"
ZIP="$OUT/Osmo-notarized.zip"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "→ regenerating project…"
xcodegen generate >/dev/null

echo "→ building Release with Hardened Runtime + Developer ID signing…"
# Override the dev-signing settings from project.yml for a real distributable
# build. --options runtime enables the Hardened Runtime that notarization needs;
# --deep + xcodebuild re-sign every bundled framework (Sparkle, SQLCipher, GRDB)
# with our Developer ID.
xcodebuild -project Osmo.xcodeproj -scheme Osmo -configuration Release \
  -derivedDataPath "$OUT/dd" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$OSMO_SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$OSMO_TEAM_ID" \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  ${OSMO_VERSION:+MARKETING_VERSION=$OSMO_VERSION} \
  build | tail -3

BUILT="$OUT/dd/Build/Products/Release/Osmo.app"
[ -d "$BUILT" ] || fail "build did not produce $BUILT"
cp -R "$BUILT" "$APP"

echo "→ deep re-signing inside-out (Developer ID + hardened runtime + secure timestamp)…"
# xcodebuild does NOT reliably re-sign/timestamp deeply-nested framework helpers
# (Sparkle's XPC services, Autoupdate, Updater.app) and it injects the debug
# get-task-allow entitlement — both make Apple notarization FAIL. Re-sign every
# nested Mach-O inside-out, then the app with our entitlements (which lack
# get-task-allow), all with --timestamp --options runtime.
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for t in \
  "$SP/XPCServices/Installer.xpc" \
  "$SP/XPCServices/Downloader.xpc" \
  "$SP/Autoupdate" \
  "$SP/Updater.app/Contents/MacOS/Updater" \
  "$SP/Updater.app" \
  "$APP/Contents/Frameworks/Sparkle.framework" \
  "$APP/Contents/Frameworks/SQLCipher.framework" ; do
  [ -e "$t" ] && codesign --force --options runtime --timestamp --sign "$OSMO_SIGN_IDENTITY" "$t" >/dev/null 2>&1 || true
done
codesign --force --options runtime --timestamp --entitlements App/Osmo.entitlements --sign "$OSMO_SIGN_IDENTITY" "$APP" >/dev/null 2>&1

echo "→ verifying signature (Developer-ID, hardened runtime, no get-task-allow)…"
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign verify failed"
# NB: match on captured strings, NOT `codesign … | grep -q` — grep -q closes the
# pipe early, codesign dies with SIGPIPE, and `set -o pipefail` then reports the
# whole pipeline as failed even though the flag IS present (a false negative).
SIGINFO="$(codesign -dvvv "$APP" 2>&1 || true)"
[[ "$SIGINFO" == *"(runtime)"* ]] || fail "Hardened Runtime not enabled"
ENTS="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
[[ "$ENTS" == *"get-task-allow"* ]] && fail "get-task-allow still present" || true

echo "→ zipping for notarization…"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "→ submitting to Apple notary service (this can take a few minutes)…"
xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait || fail "notarization failed — run: xcrun notarytool log <id> ${NOTARY_AUTH[*]}"

echo "→ stapling the notarization ticket to the app…"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" || fail "staple validate failed"

echo "→ producing the final distributable zip…"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo ""
echo "✓ Notarized, stapled build ready: $ZIP"
echo "  Gatekeeper assessment:"
spctl -a -vvv "$APP" 2>&1 | sed 's/^/    /'
echo "  Upload this zip as the GitHub Release asset (replaces the unsigned one)."
