#!/usr/bin/env bash
# Install the complete private Calla Mac side. No Gateway credentials required.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
TUTOR_HOST_LABEL="com.calla.tutor-host"
NODE_HOST_LABEL="com.calla.openclaw-node-host"
LEGACY_ACCESS_PROXY_LABEL="com.calla.openclaw-access-proxy"
LEGACY_KEYCHAIN_SERVICE="com.calla.openclaw"
GATEWAY_HOST="${CALLA_GATEWAY_HOST:-nomonhomelab.tailec0dca.ts.net}"
GATEWAY_PORT="${CALLA_GATEWAY_PORT:-443}"
DISPLAY_NAME="${CALLA_NODE_DISPLAY_NAME:-Calla Mac}"
MODE="check"
YES=0

usage() {
  cat <<'EOF'
Usage: ./scripts/bootstrap-calla-mac.sh [--check|--install|--remove] [options]

Install the native TutorHost and Calla node over the private Tailscale route.
It does not request Gateway credentials or a manually copied node ID. The
Gateway automatically enrolls one node named "Calla Mac" after it connects.

Options:
  --check                 Inspect required software and Calla LaunchAgents (default)
  --install               Install and start TutorHost and the Calla node
  --remove                Remove only Calla LaunchAgents
  --yes                   Confirm --install or --remove
  --gateway-host HOST     Private Gateway hostname
  --gateway-port PORT     Private Gateway TLS port (default 443)
  --display-name NAME     Node display name (default "Calla Mac")
  -h, --help              Show this help
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --install) MODE="install" ;;
    --remove) MODE="remove" ;;
    --yes) YES=1 ;;
    --gateway-host) shift; [[ $# -gt 0 ]] || fail "--gateway-host needs a value"; GATEWAY_HOST="$1" ;;
    --gateway-port) shift; [[ $# -gt 0 ]] || fail "--gateway-port needs a value"; GATEWAY_PORT="$1" ;;
    --display-name) shift; [[ $# -gt 0 ]] || fail "--display-name needs a value"; DISPLAY_NAME="$1" ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

[[ "$GATEWAY_HOST" == *.ts.net ]] || fail "the private Calla route requires a *.ts.net Gateway hostname"
[[ "$GATEWAY_PORT" == "443" ]] || fail "the private Calla route uses TLS port 443"
[[ "$(uname -s)" == "Darwin" ]] || fail "Calla Mac bootstrap must run on macOS"

TUTOR_HOST_PLIST="$HOME/Library/LaunchAgents/$TUTOR_HOST_LABEL.plist"
NODE_HOST_PLIST="$HOME/Library/LaunchAgents/$NODE_HOST_LABEL.plist"
LEGACY_ACCESS_PROXY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_ACCESS_PROXY_LABEL.plist"
LOG_DIRECTORY="$HOME/Library/Logs/Calla"

check_prerequisites() {
  local missing=0
  for command in launchctl openclaw python3 xcrun tailscale; do
    if command -v "$command" >/dev/null 2>&1; then
      printf '  %-14s available\n' "$command"
    else
      printf '  %-14s missing\n' "$command" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || fail "install the missing Mac prerequisites"
  tailscale status --json >/dev/null || fail "Tailscale is not connected"
}

launchagent_status() {
  [[ -f "$1" ]] && echo installed || echo absent
}

remove_legacy_auth_state() {
  launchctl bootout "gui/$(id -u)" "$LEGACY_ACCESS_PROXY_PLIST" >/dev/null 2>&1 || true
  rm -f "$LEGACY_ACCESS_PROXY_PLIST"
  if command -v security >/dev/null 2>&1; then
    security delete-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -a service-token-id >/dev/null 2>&1 || true
    security delete-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -a service-token-secret >/dev/null 2>&1 || true
    security delete-generic-password -s "$LEGACY_KEYCHAIN_SERVICE" -a openclaw-gateway-token >/dev/null 2>&1 || true
  fi
}

if [[ "$MODE" == "check" ]]; then
  check_prerequisites
  printf '  %-14s %s\n' "Gateway URL" "wss://$GATEWAY_HOST:$GATEWAY_PORT"
  printf '  %-14s %s\n' "TutorHost" "$(launchagent_status "$TUTOR_HOST_PLIST")"
  printf '  %-14s %s\n' "node host" "$(launchagent_status "$NODE_HOST_PLIST")"
  printf '  %-14s %s\n' "gateway login" "not required"
  exit 0
fi

[[ "$YES" -eq 1 ]] || fail "$MODE requires --yes"
check_prerequisites

if [[ "$MODE" == "remove" ]]; then
  remove_legacy_auth_state
  launchctl bootout "gui/$(id -u)" "$TUTOR_HOST_PLIST" >/dev/null 2>&1 || true
  launchctl bootout "gui/$(id -u)" "$NODE_HOST_PLIST" >/dev/null 2>&1 || true
  rm -f "$TUTOR_HOST_PLIST" "$NODE_HOST_PLIST"
  echo "Removed Calla's TutorHost and node LaunchAgents."
  exit 0
fi

# Remove the retired credential-based transport before starting the one private
# Tailscale route. These are exact Calla-owned labels and item names.
remove_legacy_auth_state

plugin_path="$REPOSITORY_ROOT/integrations/openclaw"
openclaw plugins inspect tutor --runtime --json >/dev/null 2>&1 || openclaw plugins install "$plugin_path"
node_config='{"role":"node","stateDirectory":"~/.openclaw/tutor","requireOwnerIdentity":false}'
patch="{\"plugins\":{\"entries\":{\"tutor\":{\"enabled\":true,\"config\":$node_config}}}}"
printf '%s' "$patch" | openclaw config patch --stdin --dry-run >/dev/null
printf '%s' "$patch" | openclaw config patch --stdin >/dev/null
openclaw config validate

mkdir -p "$HOME/Library/LaunchAgents" "$LOG_DIRECTORY"
chmod 700 "$LOG_DIRECTORY"

# KeepAlive is conditional on purpose. The host has a Quit item in its menu, and
# an unconditional KeepAlive made that meaningless: launchd brought it straight
# back, so a learner who quit Calla got it again seconds later. SuccessfulExit
# false restarts it when it dies — a crash, or the SIGPIPE this ignores now —
# and leaves it down when it exits cleanly, which is what Quit does. The same
# rule lets the "another host already holds the socket" stand-down settle
# instead of looping.
cat >"$TUTOR_HOST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$TUTOR_HOST_LABEL</string>
  <key>ProgramArguments</key><array><string>$SCRIPT_DIRECTORY/calla-tutor-host.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>StandardOutPath</key><string>$LOG_DIRECTORY/tutor-host.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIRECTORY/tutor-host.log</string>
</dict></plist>
EOF
chmod 600 "$TUTOR_HOST_PLIST"
launchctl bootout "gui/$(id -u)" "$TUTOR_HOST_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$TUTOR_HOST_PLIST"

cat >"$NODE_HOST_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$NODE_HOST_LABEL</string>
  <key>ProgramArguments</key><array><string>$SCRIPT_DIRECTORY/calla-node-host.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>CALLA_NODE_GATEWAY_HOST</key><string>$GATEWAY_HOST</string>
    <key>CALLA_NODE_GATEWAY_PORT</key><string>$GATEWAY_PORT</string>
    <key>CALLA_NODE_GATEWAY_TLS</key><string>true</string>
    <key>CALLA_NODE_DISPLAY_NAME</key><string>$DISPLAY_NAME</string>
  </dict>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_DIRECTORY/node-host.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIRECTORY/node-host.log</string>
</dict></plist>
EOF
chmod 600 "$NODE_HOST_PLIST"
launchctl bootout "gui/$(id -u)" "$NODE_HOST_PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$NODE_HOST_PLIST"

echo "Calla is running. TutorHost and node host are started; the Gateway will automatically enroll this Mac when it connects."
