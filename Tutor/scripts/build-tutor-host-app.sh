#!/usr/bin/env bash
# Build and install "Calla TutorHost.app".
#
# The host has to be a real application bundle rather than a bare binary for two
# reasons. Screen Recording is granted to an application identity, and a bundle
# is what gives the host a stable name and identifier in System Settings instead
# of a build-directory path that moves. And the overlay renderer only composites
# when it is its own application, so it ships nested at Contents/Helpers.
#
# Signing matters for the same reason: ad-hoc signing has no identity, so macOS
# ties the grant to the code hash and revokes it on every rebuild.
# scripts/calla-signing-identity.sh creates a local certificate that makes the
# grant survive; without it this falls back to ad-hoc and one approval per build.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
HOST_PACKAGE="$REPOSITORY_ROOT/apps/macos/TutorHost"
DESTINATION="${CALLA_APP_DESTINATION:-$HOME/Applications}"
APP="$DESTINATION/Calla TutorHost.app"
BUILD_ONLY=0
RESTART=1

usage() {
  cat <<'EOF'
Usage: ./scripts/build-tutor-host-app.sh [options]

Build the release TutorHost and overlay renderer, assemble them into
"Calla TutorHost.app", and install it into ~/Applications.

Options:
  --build-only   Assemble the bundle without restarting a running host
  --no-restart   Alias for --build-only
  -h, --help     Show this help

Environment:
  CALLA_APP_DESTINATION   Install directory (default: ~/Applications)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only|--no-restart) BUILD_ONLY=1; RESTART=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || { echo "ERROR: this builds a macOS application bundle" >&2; exit 1; }
command -v xcrun >/dev/null 2>&1 || { echo "ERROR: install the Xcode Command Line Tools" >&2; exit 1; }

echo "Building the release host and overlay renderer..."
xcrun swift build --package-path "$HOST_PACKAGE" -c release
BINARY_DIRECTORY="$(xcrun swift build --package-path "$HOST_PACKAGE" -c release --show-bin-path)"

for required in CallaTutorHost CallaOverlayHelper; do
  [[ -x "$BINARY_DIRECTORY/$required" ]] || { echo "ERROR: $required did not build" >&2; exit 1; }
done

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/Calla TutorHost.app"
HELPER_APP="$STAGED_APP/Contents/Helpers/CallaOverlayHelper.app"

mkdir -p "$STAGED_APP/Contents/MacOS" "$HELPER_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
# The tooltip's own buttons need a way to reach Calla, and the installed bundle
# has no checkout to find it in.
cp "$SCRIPT_DIRECTORY/calla-ask.sh" "$STAGED_APP/Contents/Resources/calla-ask.sh"
chmod +x "$STAGED_APP/Contents/Resources/calla-ask.sh"
cp "$SCRIPT_DIRECTORY/calla-course.sh" "$STAGED_APP/Contents/Resources/calla-course.sh"
chmod +x "$STAGED_APP/Contents/Resources/calla-course.sh"
cp "$SCRIPT_DIRECTORY/calla-gateway-check.sh" "$STAGED_APP/Contents/Resources/calla-gateway-check.sh"
chmod +x "$STAGED_APP/Contents/Resources/calla-gateway-check.sh"
# Courses can be authored from the installed Settings window too. Ship its
# research brief beside the host, rather than relying on a development checkout
# being an ancestor of ~/Applications/Calla TutorHost.app.
RESEARCH_PROMPT="$REPOSITORY_ROOT/docs/course-research-prompt.md"
[[ -f "$RESEARCH_PROMPT" ]] || { echo "ERROR: missing $RESEARCH_PROMPT" >&2; exit 1; }
cp "$RESEARCH_PROMPT" "$STAGED_APP/Contents/Resources/course-research-prompt.md"
mkdir -p "$STAGED_APP/Contents/Resources"
cp "$REPOSITORY_ROOT/apps/macos/TutorHost/assets/blender/wrench-template-5.2.png" \
  "$STAGED_APP/Contents/Resources/blender-wrench-template-5.2.png"
cp "$BINARY_DIRECTORY/CallaTutorHost" "$STAGED_APP/Contents/MacOS/CallaTutorHost"
cp "$BINARY_DIRECTORY/CallaOverlayHelper" "$HELPER_APP/Contents/MacOS/CallaOverlayHelper"

# LSUIElement on both: the host lives in the menu bar and the renderer must
# never take focus away from the application the learner is being taught.
cat >"$STAGED_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Calla TutorHost</string>
  <key>CFBundleExecutable</key><string>CallaTutorHost</string>
  <key>CFBundleIconFile</key><string>Calla</string>
  <key>CFBundleIdentifier</key><string>com.calla.tutor-host</string>
  <key>CFBundleName</key><string>Calla TutorHost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAccessibilityUsageDescription</key><string>Calla resolves the control a lesson is about on this Mac.</string>
</dict></plist>
EOF

cat >"$HELPER_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Calla Overlay</string>
  <key>CFBundleIdentifier</key><string>com.calla.tutor-host.overlay</string>
  <key>CFBundleExecutable</key><string>CallaOverlayHelper</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

# The icon is rendered from the same artwork Calla draws on screen, so the mark
# in the Dock, the menu bar, and the pointer over the lesson are one thing.
# qlmanage is the SVG rasteriser every Mac already has.
ICON_SOURCE="$REPOSITORY_ROOT/apps/macos/TutorHost/assets/calla-icon.svg"
if [[ -f "$ICON_SOURCE" ]]; then
  ICON_WORK="$STAGING/icon"
  ICONSET="$ICON_WORK/Calla.iconset"
  mkdir -p "$ICONSET"
  cp "$ICON_SOURCE" "$ICON_WORK/calla-icon.svg"
  (cd "$ICON_WORK" && qlmanage -t -s 1024 -o . calla-icon.svg >/dev/null 2>&1)
  MASTER="$ICON_WORK/calla-icon.svg.png"
  if [[ -f "$MASTER" ]]; then
    for size in 16 32 128 256 512; do
      sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null 2>&1
      sips -z "$((size * 2))" "$((size * 2))" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null 2>&1
    done
    mkdir -p "$STAGED_APP/Contents/Resources"
    iconutil -c icns "$ICONSET" -o "$STAGED_APP/Contents/Resources/Calla.icns" 2>/dev/null \
      || echo "note: could not build Calla.icns; the app will use the generic icon" >&2
  else
    echo "note: could not rasterise $ICON_SOURCE; the app will use the generic icon" >&2
  fi
fi

# Sign with the local identity when there is one, inner bundle first. That is
# what gives the bundle a designated requirement naming its identifier and
# certificate rather than its bytes, so a Screen Recording grant survives a
# rebuild. Ad-hoc is the fallback and costs an approval per build.
SIGNING_IDENTITY="${CALLA_SIGNING_IDENTITY:-Calla Local Signing}"
if security find-certificate -c "$SIGNING_IDENTITY" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  SIGN_WITH="$SIGNING_IDENTITY"
  echo "Signing with $SIGNING_IDENTITY"
else
  SIGN_WITH="-"
  echo "Signing ad-hoc; run ./scripts/calla-signing-identity.sh to keep permissions across rebuilds."
fi
codesign --force --sign "$SIGN_WITH" --identifier com.calla.tutor-host.overlay "$HELPER_APP"
codesign --force --sign "$SIGN_WITH" --identifier com.calla.tutor-host "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

AGENT_LABEL="com.calla.tutor-host"
AGENT_MANAGED=0
if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then AGENT_MANAGED=1; fi

# A managed host is restarted by launchctl below, after the new bundle is in
# place. Killing it here instead would only make launchd relaunch the old binary
# from a bundle that is about to be replaced.
if [[ "$RESTART" -eq 1 && "$AGENT_MANAGED" -eq 0 ]] \
   && pgrep -f "Calla TutorHost.app/Contents/MacOS/CallaTutorHost" >/dev/null 2>&1; then
  echo "Stopping the running TutorHost..."
  pkill -f "Calla TutorHost.app/Contents/MacOS/CallaTutorHost" || true
  pkill -f "CallaOverlayHelper.app/Contents/MacOS/CallaOverlayHelper" || true
  sleep 1
fi

mkdir -p "$DESTINATION"
rm -rf "$APP"
# Move rather than copy so the installed bundle is never half-written.
mv "$STAGED_APP" "$APP"
echo "Installed $APP"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  echo "Skipped starting the host (--build-only)."
  exit 0
fi

# Let launchd own the process when it is managing one. `open -a` beside a
# KeepAlive agent is what left two hosts running against one socket, and the
# loser of that argument took the lesson's overlay down with it. The host now
# stands down when it finds another one already listening, so any host left over
# from an earlier `open -a` has to go first — otherwise it holds the socket and
# launchd's copy would quit and be restarted on a loop.
if [[ "$AGENT_MANAGED" -eq 1 ]]; then
  echo "Restarting the $AGENT_LABEL LaunchAgent..."
  pkill -f "Calla TutorHost.app/Contents/MacOS/CallaTutorHost" || true
  pkill -f "CallaOverlayHelper.app/Contents/MacOS/CallaOverlayHelper" || true
  sleep 1
  launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL"
else
  open -a "$APP"
fi
echo
cat <<EOF
Calla TutorHost is running in the menu bar.

macOS asks for Screen Recording the first time a lesson requests a window
capture. Signed with $SIGN_WITH, that approval is tied to the signing identity
rather than to the exact bytes, so a rebuild keeps it. Approve "Calla TutorHost"
here, and teaching works without Accessibility:

  System Settings > Privacy & Security > Screen & System Audio Recording

Check the whole path with:
  python3 tools/calla_guide_probe.py --bundle-id <the app you want taught>
EOF
