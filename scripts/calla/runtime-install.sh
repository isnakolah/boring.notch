#!/usr/bin/env bash
# Install only Boring-owned local Calla runtime labels. Legacy plists/data stay.
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/boringNotch/Calla"
SOCKET_DIRECTORY="$APP_SUPPORT"
APP="/Applications/boringNotch.app"
RESOURCES="$APP/Contents/Resources/Calla"
NODE_LABEL="theboringteam.boringnotch.calla-node"
RUNTIME_LABEL="theboringteam.boringnotch.calla-runtime"
AGENT_DIRECTORY="$HOME/Library/LaunchAgents"
LAUNCH_RUNTIME="${CALLA_RUNTIME_LAUNCH:-1}"
mkdir -p "$SOCKET_DIRECTORY" "$APP_SUPPORT/logs"
chmod 700 "$SOCKET_DIRECTORY" "$APP_SUPPORT/logs"
[[ -x "$APP/Contents/MacOS/boringNotch" ]] || { echo "Boring Notch is not installed at $APP" >&2; exit 78; }
[[ -x "$RESOURCES/scripts/calla-node-host.sh" ]] || { echo "embedded Calla node runtime is missing" >&2; exit 78; }

# New local node loads exactly bundled plugin source. Keep every unrelated
# plugin path, remove only known Calla source/resource paths, then add exactly
# one Boring-owned source. Two active Calla paths make node contracts ambiguous.
plugin_path="$RESOURCES/openclaw"
existing_paths="$(openclaw config get plugins.load.paths --json 2>/dev/null || printf '[]')"
merged_paths="$(CALLA_PLUGIN_PATH="$plugin_path" CALLA_EXISTING_PATHS="$existing_paths" python3 -c '
import json, os
try:
    paths = json.loads(os.environ["CALLA_EXISTING_PATHS"])
except json.JSONDecodeError:
    paths = []
if not isinstance(paths, list) or not all(isinstance(item, str) for item in paths):
    raise SystemExit("plugins.load.paths is not a string array")
target = os.environ["CALLA_PLUGIN_PATH"]
legacy = ("calla-openclaw/apps/tutor/integrations/openclaw", "/Calla/openclaw", "open-desktop-tutor")
kept = [item for item in paths if item != target and not any(marker in item for marker in legacy)]
print(json.dumps([*kept, target], separators=(",", ":")))
')"
node_config="{\"role\":\"node\",\"stateDirectory\":\"~/.openclaw/tutor\",\"requireOwnerIdentity\":false}"
config_patch="{\"plugins\":{\"load\":{\"paths\":$merged_paths},\"entries\":{\"tutor\":{\"enabled\":true,\"config\":$node_config}}}}"
printf '%s' "$config_patch" | openclaw config patch --stdin --dry-run >/dev/null
printf '%s' "$config_patch" | openclaw config patch --stdin >/dev/null
openclaw config validate

mkdir -p "$AGENT_DIRECTORY"
# Keep a named node ownership receipt for diagnostics and future launchd
# inspection. Do not bootstrap it: BoringCallaEngine is sole node parent while
# Boring runs. Bootstrapping this plist would create a second Calla Mac node.
cat >"$AGENT_DIRECTORY/$NODE_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$NODE_LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/true</string></array>
  <key>Disabled</key><true/>
  <key>RunAtLoad</key><false/><key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$APP_SUPPORT/logs/node-host.log</string>
  <key>StandardErrorPath</key><string>$APP_SUPPORT/logs/node-host.log</string>
</dict></plist>
EOF
chmod 600 "$AGENT_DIRECTORY/$NODE_LABEL.plist"

# Engine is embedded XPC, launched and held by Boring app. This label restores
# Boring after login without reintroducing a separate visible TutorHost app.
cat >"$AGENT_DIRECTORY/$RUNTIME_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$RUNTIME_LABEL</string>
  <key>ProgramArguments</key><array><string>/usr/bin/open</string><string>-gj</string><string>$APP</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$APP_SUPPORT/logs/runtime.log</string>
  <key>StandardErrorPath</key><string>$APP_SUPPORT/logs/runtime.log</string>
</dict></plist>
EOF
chmod 600 "$AGENT_DIRECTORY/$RUNTIME_LABEL.plist"

launchctl bootout "gui/$(id -u)/$NODE_LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$RUNTIME_LABEL" 2>/dev/null || true

# Cutover intentionally unloads old agents before Boring starts its engine, so
# only one process can present itself as Calla Mac. Plists, app, logs, and
# ~/Library/Application Support/CallaTutor data are deliberately retained.
launchctl bootout "gui/$(id -u)/com.calla.tutor-host" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/com.calla.openclaw-node-host" 2>/dev/null || true

if [[ "$LAUNCH_RUNTIME" == 1 ]]; then
  launchctl bootstrap "gui/$(id -u)" "$AGENT_DIRECTORY/$RUNTIME_LABEL.plist"
fi

echo "Boring Calla runtime installed: $APP_SUPPORT (node owned by embedded engine)"
