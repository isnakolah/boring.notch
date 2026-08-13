#!/usr/bin/env bash
#
# deploy.sh — build boringNotch and install it to /Applications.
#
# Deploys DEBUG by default. Debug uses persistent local `Calla Local Signing`
# identity for app and XPC helper, keeping TCC grants stable across local
# rebuilds. Current private Release builds use that same local identity and
# disable hardened runtime: it cannot load Boring's locally signed OpenSSL
# framework under library validation. Restore Developer ID signing and hardened
# runtime together before any external distribution.
#
# Usage:
#   scripts/deploy.sh                 # build Debug, install, relaunch
#   scripts/deploy.sh --config Release
#   scripts/deploy.sh --no-launch     # install but don't relaunch
#   scripts/deploy.sh --skip-build    # reuse the last build product
#   scripts/deploy.sh --allow-signing-change
#                                  # replace app even if TCC identity changes
#
set -euo pipefail

CONFIG="Debug"
LAUNCH=1
BUILD=1
ALLOW_SIGNING_CHANGE=0
STAGING_DIR=""

cleanup() {
  [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]] && rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    --skip-build) BUILD=0; shift ;;
    --allow-signing-change) ALLOW_SIGNING_CHANGE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

SCHEME="boringNotch"
APP_NAME="boringNotch.app"
DEST="/Applications/$APP_NAME"
HELPER_RELATIVE_PATH="Contents/XPCServices/BoringNotchXPCHelper.xpc"
CALLA_ENGINE_RELATIVE_PATH="Contents/XPCServices/BoringCallaEngine.xpc"
SWEEP_SERVICE_RELATIVE_PATH="Contents/XPCServices/SweepService.xpc"
APP_BUNDLE_ID="theboringteam.boringnotch"
HELPER_BUNDLE_ID="theboringteam.boringnotch.BoringNotchXPCHelper"
CALLA_ENGINE_BUNDLE_ID="theboringteam.boringnotch.BoringCallaEngine"
SWEEP_SERVICE_BUNDLE_ID="theboringteam.boringnotch.SweepService"

bundle_identifier() {
  codesign -d --verbose=2 "$1" 2>&1 | sed -n 's/^Identifier=//p'
}

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

verify_signed_bundle() {
  local bundle="$1"
  local expected_identifier="$2"
  local actual_identifier

  codesign --verify --deep --strict "$bundle"
  actual_identifier="$(bundle_identifier "$bundle")"
  if [[ "$actual_identifier" != "$expected_identifier" ]]; then
    echo "✗ Unexpected bundle identifier for $bundle: $actual_identifier" >&2
    exit 1
  fi
}

verify_tcc_identity() {
  local source="$1"
  local installed="$2"
  local source_requirement installed_requirement

  source_requirement="$(designated_requirement "$source")"
  installed_requirement="$(designated_requirement "$installed")"
  if [[ -z "$source_requirement" || -z "$installed_requirement" ]]; then
    echo "✗ Could not read code-signing designated requirement" >&2
    exit 1
  fi
  if [[ "$source_requirement" != "$installed_requirement" && "$ALLOW_SIGNING_CHANGE" != 1 ]]; then
    cat >&2 <<EOF
✗ Signing identity changed. Refusing deployment because macOS privacy grants,
  including Calendar and Accessibility, are tied to this designated requirement.
  Rebuild with the existing signing identity, or rerun with --allow-signing-change
  only if reauthorizing those permissions is intended.
EOF
    exit 1
  fi
}

echo "▸ Config: $CONFIG"

if [[ "$BUILD" == 1 ]]; then
  echo "▸ Building $SCHEME ($CONFIG)…"
  BUILD_LOG="$(mktemp -t boringNotch-build.XXXXXX)"
  if ! xcodebuild -project boringNotch.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" build >"$BUILD_LOG" 2>&1; then
    rg -n "error:|BUILD FAILED" "$BUILD_LOG" >&2 || tail -80 "$BUILD_LOG" >&2
    rm -f "$BUILD_LOG"
    exit 1
  fi
  rg "BUILD SUCCEEDED" "$BUILD_LOG" || true
  rm -f "$BUILD_LOG"
fi

# Locate newest built .app in DerivedData. Multiple DerivedData directories can
# coexist after project changes; deploying the first `find` result is not safe.
SRC="$(find "$HOME/Library/Developer/Xcode/DerivedData"/boringNotch-*/Build/Products/"$CONFIG" \
  -maxdepth 1 -type d -name "$APP_NAME" -print0 2>/dev/null | \
  xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn | head -1 | cut -d ' ' -f 2-)"
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "✗ Could not find built $APP_NAME for $CONFIG" >&2
  exit 1
fi
echo "▸ Source: $SRC"

verify_signed_bundle "$SRC" "$APP_BUNDLE_ID"
verify_signed_bundle "$SRC/$HELPER_RELATIVE_PATH" "$HELPER_BUNDLE_ID"
verify_signed_bundle "$SRC/$CALLA_ENGINE_RELATIVE_PATH" "$CALLA_ENGINE_BUNDLE_ID"
verify_signed_bundle "$SRC/$SWEEP_SERVICE_RELATIVE_PATH" "$SWEEP_SERVICE_BUNDLE_ID"
for required_resource in Calla/openclaw Calla/packs Calla/agent-workspace Calla/scripts Calla/Gateway; do
  [[ -d "$SRC/Contents/Resources/$required_resource" ]] || { echo "✗ Missing embedded Tutor resource: $required_resource" >&2; exit 1; }
done
for required_file in \
  Contents/XPCServices/BoringCallaEngine.xpc/Contents/Resources/CallaRuntime/CallaTutorHost \
  Contents/XPCServices/BoringCallaEngine.xpc/Contents/Resources/CallaRuntime/CallaOverlayHelper \
  Contents/XPCServices/BoringCallaEngine.xpc/Contents/Resources/CallaRuntime/scripts/calla-ask.sh \
  Contents/XPCServices/BoringCallaEngine.xpc/Contents/Resources/CallaRuntime/scripts/calla-course.sh \
  Contents/XPCServices/BoringCallaEngine.xpc/Contents/Resources/CallaRuntime/scripts/calla-gateway-check.sh \
  Contents/Resources/Calla/openclaw/openclaw.plugin.json \
  Contents/Resources/Calla/scripts/calla-node-host.sh \
  Contents/Resources/Calla/scripts/gateway-update.sh \
  Contents/Resources/Calla/Gateway/calla-gateway.tar.gz; do
  [[ -x "$SRC/$required_file" || -f "$SRC/$required_file" ]] || { echo "✗ Missing embedded Tutor file: $required_file" >&2; exit 1; }
done
tar -tzf "$SRC/Contents/Resources/Calla/Gateway/calla-gateway.tar.gz" | rg -qx 'release/manifest.json' \
  || { echo "✗ Embedded Calla Gateway archive lacks release manifest" >&2; exit 1; }
for forbidden_file in \
  Contents/Resources/Calla/scripts/bootstrap-calla-mac.sh \
  Contents/Resources/Calla/scripts/setup-macos.sh \
  Contents/XPCServices/BoringCallaEngine.xpc/Contents/Resources/CallaRuntime/scripts/bootstrap-calla-mac.sh; do
  [[ ! -e "$SRC/$forbidden_file" ]] || { echo "✗ Retired Tutor bootstrap leaked into Boring: $forbidden_file" >&2; exit 1; }
done

if [[ -d "$DEST" ]]; then
  verify_signed_bundle "$DEST" "$APP_BUNDLE_ID"
  verify_signed_bundle "$DEST/$HELPER_RELATIVE_PATH" "$HELPER_BUNDLE_ID"
  if [[ -d "$DEST/$SWEEP_SERVICE_RELATIVE_PATH" ]]; then
    verify_signed_bundle "$DEST/$SWEEP_SERVICE_RELATIVE_PATH" "$SWEEP_SERVICE_BUNDLE_ID"
  fi
  verify_tcc_identity "$SRC" "$DEST"
  verify_tcc_identity "$SRC/$HELPER_RELATIVE_PATH" "$DEST/$HELPER_RELATIVE_PATH"
  if [[ -d "$DEST/$CALLA_ENGINE_RELATIVE_PATH" ]]; then
    verify_signed_bundle "$DEST/$CALLA_ENGINE_RELATIVE_PATH" "$CALLA_ENGINE_BUNDLE_ID"
    verify_tcc_identity "$SRC/$CALLA_ENGINE_RELATIVE_PATH" "$DEST/$CALLA_ENGINE_RELATIVE_PATH"
  else
    echo "▸ Existing Boring install predates Calla engine; adding new XPC service."
  fi
  if [[ -d "$DEST/$SWEEP_SERVICE_RELATIVE_PATH" ]]; then
    verify_tcc_identity "$SRC/$SWEEP_SERVICE_RELATIVE_PATH" "$DEST/$SWEEP_SERVICE_RELATIVE_PATH"
  fi
fi

echo "▸ Quitting running app…"
osascript -e 'quit app "boringNotch"' 2>/dev/null || true
sleep 1
pkill -f "$DEST" 2>/dev/null || true
sleep 1

echo "▸ Installing to ${DEST}…"
STAGING_DIR="$(mktemp -d /Applications/.boringNotch-deploy.XXXXXX)"
STAGED_APP="$STAGING_DIR/$APP_NAME"
BACKUP_APP="$STAGING_DIR/previous-$APP_NAME"
ditto "$SRC" "$STAGED_APP"
verify_signed_bundle "$STAGED_APP" "$APP_BUNDLE_ID"
verify_signed_bundle "$STAGED_APP/$HELPER_RELATIVE_PATH" "$HELPER_BUNDLE_ID"
verify_signed_bundle "$STAGED_APP/$CALLA_ENGINE_RELATIVE_PATH" "$CALLA_ENGINE_BUNDLE_ID"
verify_signed_bundle "$STAGED_APP/$SWEEP_SERVICE_RELATIVE_PATH" "$SWEEP_SERVICE_BUNDLE_ID"

if [[ -d "$DEST" ]]; then
  mv "$DEST" "$BACKUP_APP"
fi
if ! mv "$STAGED_APP" "$DEST"; then
  [[ -d "$BACKUP_APP" ]] && mv "$BACKUP_APP" "$DEST"
  echo "✗ Install failed; restored previous app bundle." >&2
  exit 1
fi

[[ -d "$DEST/Contents/XPCServices/BoringNotchXPCHelper.xpc" ]] \
  && echo "  ✓ XPC helper embedded" \
  || echo "  ⚠ XPC helper NOT found"
[[ -d "$DEST/Contents/XPCServices/BoringCallaEngine.xpc" ]] \
  && echo "  ✓ Calla engine embedded" \
  || { echo "  ✗ Calla engine NOT found" >&2; exit 1; }

# Boring owns the replacement plugin path and launch labels. This never deletes
# retired Calla plists/data; it unloads only their active jobs after the new
# Boring resources have been verified and installed.
echo "▸ Installing Boring Calla local runtime…"
CALLA_RUNTIME_LAUNCH="$LAUNCH" /bin/bash "$PROJECT_DIR/scripts/calla/runtime-install.sh"
[[ -d "$DEST/$SWEEP_SERVICE_RELATIVE_PATH" ]] \
  && echo "  ✓ Sweep service embedded" \
  || { echo "  ✗ Sweep service NOT found" >&2; exit 1; }

if [[ "$LAUNCH" == 1 ]]; then
  echo "▸ Launching…"
  open -a "$DEST"
  for _ in {1..15}; do
    if pgrep -f "$DEST/Contents/MacOS/boringNotch" >/dev/null; then
      echo "  ✓ running"
      break
    fi
    sleep 1
  done
  if ! pgrep -f "$DEST/Contents/MacOS/boringNotch" >/dev/null; then
    echo "  ✗ not running — check ~/Library/Logs/DiagnosticReports/boringNotch-*.ips" >&2
    exit 1
  fi
fi

echo "✓ Deployed."
