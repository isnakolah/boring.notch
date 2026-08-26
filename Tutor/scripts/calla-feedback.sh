#!/usr/bin/env bash
# Send a bounded, committed Tutor feedback request to Gateway owner socket.
# stdin/stdout only; this script never logs screenshot bytes or model output.
set -euo pipefail

REQUEST="$(cat)"
[[ -n "$REQUEST" ]] || { echo '{"ok":false,"code":"INVALID_REQUEST","message":"Feedback request is empty."}'; exit 2; }
[[ ${#REQUEST} -le $((5 * 1024 * 1024)) ]] || { echo '{"ok":false,"code":"INVALID_REQUEST","message":"Feedback request is too large."}'; exit 2; }

GATEWAY_SSH="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
CONTROL="/tmp/calla-feedback.sock"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8
          -o ControlMaster=auto -o "ControlPath=$CONTROL" -o ControlPersist=8h)

printf '%s\n' "$REQUEST" | ssh "${SSH_OPTS[@]}" "$GATEWAY_SSH" "\$HOME/.local/bin/calla-feedback"
