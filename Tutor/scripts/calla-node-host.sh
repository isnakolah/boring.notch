#!/usr/bin/env bash
# LaunchAgent entrypoint for the private, no-login Calla Gateway.
set -euo pipefail

# launchd starts agents with a minimal PATH that omits Homebrew and npm global
# prefixes, so resolve the OpenClaw binary explicitly before exec.
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH
OPENCLAW_BIN="${CALLA_OPENCLAW_BIN:-$(command -v openclaw || true)}"
[[ -n "$OPENCLAW_BIN" ]] || { echo "openclaw not found on PATH: $PATH" >&2; exit 127; }

GATEWAY_HOST="${CALLA_NODE_GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${CALLA_NODE_GATEWAY_PORT:-18790}"
GATEWAY_TLS="${CALLA_NODE_GATEWAY_TLS:-false}"
DISPLAY_NAME="${CALLA_NODE_DISPLAY_NAME:-Calla Mac}"

# Boring Engine supplies a per-launch 0600 config containing its rotating
# ingress token.  Standalone keeps the owner's normal OpenClaw config.
if [[ -n "${CALLA_NODE_CONFIG_PATH:-}" ]]; then
  [[ -f "$CALLA_NODE_CONFIG_PATH" && ! -L "$CALLA_NODE_CONFIG_PATH" ]] || {
    echo "Boring node config is unavailable" >&2; exit 78;
  }
  export OPENCLAW_CONFIG_PATH="$CALLA_NODE_CONFIG_PATH"
fi

arguments=(node run --host "$GATEWAY_HOST" --port "$GATEWAY_PORT" --display-name "$DISPLAY_NAME")
if [[ "$GATEWAY_TLS" == "true" ]]; then
  arguments+=(--tls)
fi
exec "$OPENCLAW_BIN" "${arguments[@]}"
