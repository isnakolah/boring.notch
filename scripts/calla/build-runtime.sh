#!/usr/bin/env bash
# Build Boring's hidden Tutor runtime into an XPC resource directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:?usage: build-runtime.sh <resource-directory>}"
PACKAGE="$ROOT/Tutor/apps/macos/TutorHost"
CONFIGURATION="${CONFIGURATION:-Debug}"
SWIFT_CONFIGURATION="debug"
[[ "$CONFIGURATION" == "Release" ]] && SWIFT_CONFIGURATION="release"

xcrun swift build --package-path "$PACKAGE" -c "$SWIFT_CONFIGURATION" >/dev/null
BINARIES="$(xcrun swift build --package-path "$PACKAGE" -c "$SWIFT_CONFIGURATION" --show-bin-path)"
for executable in CallaTutorHost CallaOverlayHelper; do
  [[ -x "$BINARIES/$executable" ]] || { echo "missing Tutor runtime executable: $executable" >&2; exit 78; }
done

HOST_APP="$DESTINATION/CallaTutorHost.app"
/bin/rm -f "$DESTINATION/CallaTutorHost"
mkdir -p "$DESTINATION/assets/blender" "$DESTINATION/scripts" "$HOST_APP/Contents/MacOS"
ditto "$BINARIES/CallaTutorHost" "$HOST_APP/Contents/MacOS/CallaTutorHost"
ditto "$ROOT/scripts/calla/CallaTutorHost-Info.plist" "$HOST_APP/Contents/Info.plist"
ditto "$BINARIES/CallaOverlayHelper" "$DESTINATION/CallaOverlayHelper"
# TCC identifies each executable that calls CoreGraphics/ScreenCaptureKit.
# Keep the embedded helpers under Boring's real signing identity; ad-hoc
# signatures cannot receive the Screen Recording grant that Boring requests.
if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" && "${EXPANDED_CODE_SIGN_IDENTITY}" != "-" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HOST_APP"
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DESTINATION/CallaOverlayHelper"
else
  echo "missing expanded Boring signing identity for embedded Calla runtime" >&2
  exit 78
fi
# Old Tutor bootstrap/install/signing scripts create a second visible app and
# old launch agents. The embedded runtime needs only these private relays.
for script in calla-ask.sh calla-course.sh calla-gateway-check.sh; do
  ditto "$ROOT/Tutor/scripts/$script" "$DESTINATION/scripts/$script"
  chmod 700 "$DESTINATION/scripts/$script"
done
ditto "$ROOT/Tutor/apps/macos/TutorHost/assets/blender" "$DESTINATION/assets/blender"
chmod 700 "$HOST_APP/Contents/MacOS/CallaTutorHost" "$DESTINATION/CallaOverlayHelper"
