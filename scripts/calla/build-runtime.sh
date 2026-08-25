#!/usr/bin/env bash
# Build Boring's hidden Tutor runtime into an XPC resource directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="${1:?usage: build-runtime.sh <resource-directory>}"
PACKAGE="$ROOT/Tutor/apps/macos/TutorHost"
CONFIGURATION="${CONFIGURATION:-Debug}"
SWIFT_CONFIGURATION="debug"
[[ "$CONFIGURATION" == "Release" ]] && SWIFT_CONFIGURATION="release"

# CI builds intentionally have no TCC-capable identity. They produce a compile
# artifact only: never install it, never claim its permissions, and never use
# it as a deployment payload. Installed builds still require real identity.
SIGN_CALLA_RUNTIME=1
if [[ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" || "${EXPANDED_CODE_SIGN_IDENTITY}" == "-" ]]; then
  if [[ "${CALLA_UNSIGNED_BUILD:-0}" == "1" ]]; then
    SIGN_CALLA_RUNTIME=0
    echo "Calla runtime: unsigned CI artifact (deployment-ineligible)"
  else
    echo "missing expanded Boring signing identity for embedded Calla runtime" >&2
    exit 78
  fi
fi

xcrun swift build --package-path "$PACKAGE" -c "$SWIFT_CONFIGURATION" >/dev/null
BINARIES="$(xcrun swift build --package-path "$PACKAGE" -c "$SWIFT_CONFIGURATION" --show-bin-path)"
for executable in CallaTutorHost CallaOverlayHelper; do
  [[ -x "$BINARIES/$executable" ]] || { echo "missing Tutor runtime executable: $executable" >&2; exit 78; }
done

HOST_APP="$DESTINATION/CallaTutorHost.app"
# The renderer that draws the pointer and tooltip is a nested application, the
# first place TutorHost's helper lookup looks and the layout the original Calla
# TutorHost shipped. Staged here as a loose binary instead, the lookup found
# nothing, the renderer never started, and no lesson ever showed a cursor or a
# tooltip while still reporting itself as started.
HELPER_APP="$HOST_APP/Contents/Helpers/CallaOverlayHelper.app"
/bin/rm -f "$DESTINATION/CallaTutorHost" "$DESTINATION/CallaOverlayHelper"
mkdir -p "$DESTINATION/assets/blender" "$DESTINATION/scripts" "$HOST_APP/Contents/MacOS" \
  "$HOST_APP/Contents/Resources/assets/blender" "$HELPER_APP/Contents/MacOS"
ditto "$BINARIES/CallaTutorHost" "$HOST_APP/Contents/MacOS/CallaTutorHost"
ditto "$ROOT/scripts/calla/CallaTutorHost-Info.plist" "$HOST_APP/Contents/Info.plist"
ditto "$BINARIES/CallaOverlayHelper" "$HELPER_APP/Contents/MacOS/CallaOverlayHelper"
ditto "$ROOT/scripts/calla/CallaOverlayHelper-Info.plist" "$HELPER_APP/Contents/Info.plist"
# Icon templates VisualLocator matches against, inside the host bundle so
# `Bundle.main.resourceURL` resolves them. This must stay ABOVE the codesign
# block: staging a resource into the bundle after it is sealed makes
# `codesign --verify --deep --strict` fail with "a sealed resource is missing
# or invalid", which is what deploy.sh runs.
ditto "$ROOT/Tutor/apps/macos/TutorHost/assets/blender" "$HOST_APP/Contents/Resources/assets/blender"
# TCC identifies each executable that calls CoreGraphics/ScreenCaptureKit.
# Keep the embedded helpers under Boring's real signing identity; ad-hoc
# signatures cannot receive the Screen Recording grant that Boring requests.
# Nested bundle first: the host's seal has to cover the renderer inside it.
if [[ "$SIGN_CALLA_RUNTIME" == "1" ]]; then
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HELPER_APP"
  codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$HOST_APP"
fi
# The live-call capture host. A separate SwiftPM package because it pulls a
# whisper.cpp xcframework that the Tutor host has no use for, but it ships in
# the same runtime directory and under the same identity: TCC keys the
# microphone and screen-recording grants to the signature, and an ad-hoc one
# cannot hold either.
CALLHOST_PACKAGE="$ROOT/CallaCallHost"
if [[ -d "$CALLHOST_PACKAGE" ]]; then
  xcrun swift build --package-path "$CALLHOST_PACKAGE" -c "$SWIFT_CONFIGURATION" >/dev/null
  CALLHOST_BIN="$(xcrun swift build --package-path "$CALLHOST_PACKAGE" -c "$SWIFT_CONFIGURATION" --show-bin-path)"
  if [[ -x "$CALLHOST_BIN/CallaCallHost" ]]; then
    CALLHOST_APP="$DESTINATION/CallaCallHost.app"
    /bin/rm -rf "$CALLHOST_APP"
    mkdir -p "$CALLHOST_APP/Contents/MacOS" "$CALLHOST_APP/Contents/Resources" "$CALLHOST_APP/Contents/Frameworks"
    ditto "$CALLHOST_BIN/CallaCallHost" "$CALLHOST_APP/Contents/MacOS/CallaCallHost"
    ditto "$ROOT/scripts/calla/CallaCallHost-Info.plist" "$CALLHOST_APP/Contents/Info.plist"
    # `Bundle.module` resolves against Bundle.main.resourceURL inside an app,
    # which is where the bundled Silero VAD model has to land.
    for bundle in "$CALLHOST_BIN"/*.bundle; do
      [[ -e "$bundle" ]] || continue
      ditto "$bundle" "$CALLHOST_APP/Contents/Resources/$(basename "$bundle")"
    done
    if [[ -d "$CALLHOST_BIN/whisper.framework" ]]; then
      ditto "$CALLHOST_BIN/whisper.framework" "$CALLHOST_APP/Contents/Frameworks/whisper.framework"
      install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$CALLHOST_APP/Contents/MacOS/CallaCallHost" 2>/dev/null || true
      # Strip headers and module maps before sealing. They are build-time only,
      # and something downstream removes them from an embedded framework — so a
      # signature that seals them verifies as "a sealed resource is missing or
      # invalid" against the enclosing engine bundle, not against this one.
      # Removing them first makes the seal match what actually ships.
      EMBEDDED_WHISPER="$CALLHOST_APP/Contents/Frameworks/whisper.framework"
      /bin/rm -rf "$EMBEDDED_WHISPER/Versions/A/Headers" "$EMBEDDED_WHISPER/Versions/A/Modules" \
        "$EMBEDDED_WHISPER/Headers" "$EMBEDDED_WHISPER/Modules" \
        "$EMBEDDED_WHISPER/Versions/A/_CodeSignature"
      if [[ "$SIGN_CALLA_RUNTIME" == "1" ]]; then
        codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$EMBEDDED_WHISPER"
      fi
    fi
    chmod 700 "$CALLHOST_APP/Contents/MacOS/CallaCallHost"
    if [[ "$SIGN_CALLA_RUNTIME" == "1" ]]; then
      codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$CALLHOST_APP"
    fi
  else
    echo "missing CallaCallHost executable" >&2
    exit 78
  fi
fi

# Old Tutor bootstrap/install/signing scripts create a second visible app and
# old launch agents. The embedded runtime needs only these private relays.
for script in calla-ask.sh calla-course.sh calla-gateway-check.sh; do
  ditto "$ROOT/Tutor/scripts/$script" "$DESTINATION/scripts/$script"
  chmod 700 "$DESTINATION/scripts/$script"
done
ditto "$ROOT/Tutor/apps/macos/TutorHost/assets/blender" "$DESTINATION/assets/blender"
chmod 700 "$HOST_APP/Contents/MacOS/CallaTutorHost" "$HELPER_APP/Contents/MacOS/CallaOverlayHelper"

# This phase stages bytes into the engine's own Resources, which invalidates
# whatever seal covers that bundle. On a full build Xcode's implicit CodeSign
# step runs after every build phase and re-seals it anyway; but this phase is
# `alwaysOutOfDate`, so on an incremental build where Xcode considers the
# target up to date it runs and that CodeSign step does not. Re-seal here to
# cover that case, or the next deployment fails its own verification with
# "a sealed resource is missing or invalid".
#
# Pass --entitlements explicitly. A bare `codesign --force --sign` drops the
# entitlements Xcode applied, and whichever of the two signatures lands last
# must still carry them.
ENTITLEMENTS="$ROOT/BoringCallaEngine/BoringCallaEngine.entitlements"
if [[ "$SIGN_CALLA_RUNTIME" == "1" && -n "${CODESIGNING_FOLDER_PATH:-}" && -d "${CODESIGNING_FOLDER_PATH}" ]]; then
  if [[ -f "$ENTITLEMENTS" ]]; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
      --entitlements "$ENTITLEMENTS" "$CODESIGNING_FOLDER_PATH"
  else
    echo "missing engine entitlements at $ENTITLEMENTS" >&2
    exit 78
  fi
fi
