#!/usr/bin/env bash
#
# deploy.sh — build boringNotch and install it to /Applications.
#
# Deploys the DEBUG configuration by default: Debug is ad-hoc signed WITHOUT
# hardened runtime, so it launches locally. A local Release build enables
# hardened runtime + library validation, which rejects the ad-hoc-signed
# bundled MediaRemoteAdapter.framework ("different Team IDs") and crashes at
# launch — so Release is only usable when signed with a real Developer ID.
#
# Usage:
#   scripts/deploy.sh                 # build Debug, install, relaunch
#   scripts/deploy.sh --config Release
#   scripts/deploy.sh --no-launch     # install but don't relaunch
#   scripts/deploy.sh --skip-build    # reuse the last build product
#
set -euo pipefail

CONFIG="Debug"
LAUNCH=1
BUILD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    --skip-build) BUILD=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="boringNotch"
APP_NAME="boringNotch.app"
DEST="/Applications/$APP_NAME"

echo "▸ Config: $CONFIG"

if [[ "$BUILD" == 1 ]]; then
  echo "▸ Building $SCHEME ($CONFIG)…"
  xcodebuild -project boringNotch.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" build 2>&1 | \
    grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true
fi

# Locate the freshly built .app in DerivedData.
SRC="$(find "$HOME/Library/Developer/Xcode/DerivedData"/boringNotch-*/Build/Products/"$CONFIG" \
  -maxdepth 1 -name "$APP_NAME" 2>/dev/null | head -1)"
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "✗ Could not find built $APP_NAME for $CONFIG" >&2
  exit 1
fi
echo "▸ Source: $SRC"

echo "▸ Quitting running app…"
osascript -e 'quit app "boringNotch"' 2>/dev/null || true
sleep 1
pkill -f "$DEST" 2>/dev/null || true
sleep 1

echo "▸ Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

[[ -d "$DEST/Contents/XPCServices/BoringNotchXPCHelper.xpc" ]] \
  && echo "  ✓ XPC helper embedded" \
  || echo "  ⚠ XPC helper NOT found"

if [[ "$LAUNCH" == 1 ]]; then
  echo "▸ Launching…"
  open -a "$DEST"
  sleep 6
  if pgrep -f "$DEST/Contents/MacOS/boringNotch" >/dev/null; then
    echo "  ✓ running"
  else
    echo "  ✗ not running — check ~/Library/Logs/DiagnosticReports/boringNotch-*.ips" >&2
    exit 1
  fi
fi

echo "✓ Deployed."
