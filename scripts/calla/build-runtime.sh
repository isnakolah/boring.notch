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

mkdir -p "$DESTINATION/assets/blender" "$DESTINATION/scripts"
ditto "$BINARIES/CallaTutorHost" "$DESTINATION/CallaTutorHost"
ditto "$BINARIES/CallaOverlayHelper" "$DESTINATION/CallaOverlayHelper"
# Old Tutor bootstrap/install/signing scripts create a second visible app and
# old launch agents. The embedded runtime needs only these private relays.
for script in calla-ask.sh calla-course.sh calla-gateway-check.sh; do
  ditto "$ROOT/Tutor/scripts/$script" "$DESTINATION/scripts/$script"
  chmod 700 "$DESTINATION/scripts/$script"
done
ditto "$ROOT/Tutor/apps/macos/TutorHost/assets/blender" "$DESTINATION/assets/blender"
chmod 700 "$DESTINATION/CallaTutorHost" "$DESTINATION/CallaOverlayHelper"
