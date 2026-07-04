#!/bin/bash
# Build and launch the Osmo Mac app in one step.
#   ./scripts/run.sh          → generate project, build, launch Osmo.app
#   ./scripts/run.sh --build  → build only (no launch)
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ generating Xcode project (xcodegen)…"
xcodegen generate

echo "→ building Osmo.app…"
xcodebuild -project Osmo.xcodeproj -scheme Osmo -configuration Debug \
  -derivedDataPath .build/xcode build | tail -1

APP=".build/xcode/Build/Products/Debug/Osmo.app"
echo "→ built: $APP"

if [[ "${1:-}" == "--build" ]]; then
  exit 0
fi

echo "→ launching…"
open "$APP"
echo "Osmo is running. (Grant Accessibility + Full Disk Access when it asks —"
echo " that's what lets it read the active conversation and iMessage.)"
