#!/usr/bin/env bash
# Prepare the private Calla Gateway used by the bundled macOS bootstrap.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
MODE="check"
YES=0
RESTART=1

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-calla-server.sh [--check|--install|--status] [options]

Prepare the existing OpenClaw Gateway for the bundled Mac setup. The default is
--check and never writes state. --install --yes builds the Blender 5.2 App Pack,
loads this checkout's tutor plugin, keeps the Gateway loopback-bound
with no login requirement, and configures a private Tailscale HTTPS proxy.

Options:
  --check                 Validate current private-Gateway prerequisites (default)
  --install               Install the Calla gateway and Blender defaults
  --status                Show the current Calla and Gateway state
  --yes                   Confirm --install
  --no-restart            Do not restart the Gateway during --install
  -h, --help              Show this help

Run this once on the Gateway device before using the Mac setup:
  ./scripts/setup-calla-server.sh --install --yes
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 2
}

install_node_enroller() {
  command -v systemctl >/dev/null 2>&1 || fail "systemctl is required to keep the private Calla Mac enroller ready"
  local openclaw_binary
  openclaw_binary="$(command -v openclaw)" || fail "openclaw is required to keep the private Calla Mac enroller ready"
  local unit_directory="$HOME/.config/systemd/user"
  local unit_path="$unit_directory/calla-node-enroller.service"
  mkdir -p "$unit_directory"
  cat >"$unit_path" <<EOF
[Unit]
Description=Enroll the single private Calla Mac OpenClaw node
After=openclaw-gateway.service

[Service]
Type=simple
WorkingDirectory=$REPOSITORY_ROOT
ExecStart=/usr/bin/env python3 $REPOSITORY_ROOT/tools/calla_node_enroller.py --watch --openclaw-bin $openclaw_binary
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
  chmod 600 "$unit_path"
  systemctl --user daemon-reload
  systemctl --user enable --now calla-node-enroller.service
}

install_tailscale_proxy() {
  command -v tailscale >/dev/null 2>&1 || fail "tailscale is required for the bundled private Mac connection"
  tailscale status --json >/dev/null || fail "Tailscale is not connected"
  tailscale serve --bg --https=443 http://127.0.0.1:18789
}

node_enroller_status() {
  if systemctl --user is-active --quiet calla-node-enroller.service; then
    echo "Calla node enroller: waiting for Calla Mac"
  elif systemctl --user is-enabled --quiet calla-node-enroller.service \
    && [[ "$(systemctl --user show calla-node-enroller.service --property=ExecMainStatus --value)" == "0" ]]; then
    echo "Calla node enroller: completed (Calla Mac paired)"
  else
    echo "Calla node enroller: inactive"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) MODE="check" ;;
    --install) MODE="install" ;;
    --status) MODE="status" ;;
    --yes) YES=1 ;;
    --no-restart) RESTART=0 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown option: $1" ;;
  esac
  shift
done

case "$MODE" in
  check)
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" --check
    openclaw gateway status
    tailscale serve status
    node_enroller_status
    ;;
  status)
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" --status
    openclaw gateway status
    tailscale serve status
    node_enroller_status
    ;;
  install)
    [[ "$YES" -eq 1 ]] || fail "--install requires --yes; no state was changed"
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" --check
    make -C "$REPOSITORY_ROOT" pack-build
    install_arguments=(--install --yes --app-pack "$REPOSITORY_ROOT/build/packs/blender.otpack")
    if [[ "$RESTART" -eq 1 ]]; then
      install_arguments+=(--restart)
    fi
    python3 "$REPOSITORY_ROOT/tools/calla_openclaw_setup.py" "${install_arguments[@]}"
    mkdir -p "$HOME/.local/bin"
    install -m 700 "$REPOSITORY_ROOT/scripts/calla-course-gateway.sh" "$HOME/.local/bin/calla-course"
    install -m 700 "$REPOSITORY_ROOT/scripts/calla-feedback-gateway.sh" "$HOME/.local/bin/calla-feedback"
    install_tailscale_proxy
    install_node_enroller
    printf '\nCalla private defaults are installed. The bundled Mac bootstrap can now connect over Tailscale without a Gateway login token.\n'
    printf 'The local enroller will bind the first pending node named "Calla Mac" automatically.\n'
    openclaw gateway status
    ;;
esac
