#!/usr/bin/env bash
# Assemble and sign CallaCallHost.app.
#
# The bundle exists for one reason: macOS keys the microphone and screen
# recording grants to a code signature. An ad-hoc signature cannot hold either,
# and a loose executable has no stable identity to grant them to. So the host
# ships as a real, consistently-signed .app even though it draws no UI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PACKAGE="$ROOT/CallaCallHost"
DESTINATION="${1:-/Applications/CallaCallHost.app}"
CONFIGURATION="${CONFIGURATION:-Release}"
SWIFT_CONFIGURATION="release"
[[ "$CONFIGURATION" == "Debug" ]] && SWIFT_CONFIGURATION="debug"

# Same identity the rest of Boring's Calla runtime uses. Changing it resets
# every TCC grant the user has already given, which is why deploy.sh guards it.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CALLA_SIGN_IDENTITY:-Calla Local Signing}}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "refusing to build: an ad-hoc signature cannot hold a TCC grant" >&2
  exit 78
fi

echo "building ($SWIFT_CONFIGURATION)…"
xcrun swift build --package-path "$PACKAGE" -c "$SWIFT_CONFIGURATION" >/dev/null
BINARIES="$(xcrun swift build --package-path "$PACKAGE" -c "$SWIFT_CONFIGURATION" --show-bin-path)"
[[ -x "$BINARIES/CallaCallHost" ]] || { echo "missing CallaCallHost executable" >&2; exit 78; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/CallaCallHost.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

ditto "$BINARIES/CallaCallHost" "$APP/Contents/MacOS/CallaCallHost"
ditto "$ROOT/scripts/calla/CallaCallHost-Info.plist" "$APP/Contents/Info.plist"

# `Bundle.module` resolves against Bundle.main.resourceURL inside an app, so the
# SPM resource bundle carrying the Silero VAD model belongs in Resources.
for bundle in "$BINARIES"/*.bundle; do
  [[ -e "$bundle" ]] || continue
  ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

# whisper ships as an xcframework; the dylib has to travel with the app and be
# found at a bundle-relative path rather than in the build directory.
if [[ -d "$BINARIES/whisper.framework" ]]; then
  ditto "$BINARIES/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"
  install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/CallaCallHost" 2>/dev/null || true
fi

chmod 755 "$APP/Contents/MacOS/CallaCallHost"

# Nested code first: the app's seal has to cover anything inside it.
if [[ -d "$APP/Contents/Frameworks/whisper.framework" ]]; then
  # Headers and module maps are build-time only, and an embedded framework gets
  # stripped of them downstream — sealing them makes the signature reference
  # files that will not be there. Remove first, then seal.
  EMBEDDED_WHISPER="$APP/Contents/Frameworks/whisper.framework"
  rm -rf "$EMBEDDED_WHISPER/Versions/A/Headers" "$EMBEDDED_WHISPER/Versions/A/Modules" \
    "$EMBEDDED_WHISPER/Headers" "$EMBEDDED_WHISPER/Modules" \
    "$EMBEDDED_WHISPER/Versions/A/_CodeSignature"
  codesign --force --timestamp=none --sign "$IDENTITY" "$EMBEDDED_WHISPER"
fi
codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Replace in one step so a half-copied bundle is never launchable, and so the
# running host is not overwritten underneath itself.
if [[ -d "$DESTINATION" ]]; then
  pkill -f "$DESTINATION/Contents/MacOS/CallaCallHost" 2>/dev/null || true
  rm -rf "$DESTINATION"
fi
mkdir -p "$(dirname "$DESTINATION")"
ditto "$APP" "$DESTINATION"

echo "installed $DESTINATION"
codesign -dv "$DESTINATION" 2>&1 | sed -n 's/^\(Identifier\|TeamIdentifier\|Authority\)/  &/p'
