#!/usr/bin/env bash
# Send one versioned course-control request to Gateway-local owner socket.
# No public endpoint, provider credential, or teaching session is involved.
set -euo pipefail

COMMAND="${1:-}"
[[ -n "$COMMAND" ]] || { echo "usage: calla-course.sh <command> < JSON payload" >&2; exit 2; }
PAYLOAD="$(cat)"

GATEWAY_SSH="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
CONTROL="/tmp/calla-course.sock"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8
          -o ControlMaster=auto -o "ControlPath=$CONTROL" -o ControlPersist=8h)

# A course's starter scenes are megabytes of .blend, and the control socket
# hangs up on any request over 128 KiB, so they cannot travel inside the
# payload. They go over the same multiplexed SSH connection as a file instead.
#
# This is why the Mac names a local zip rather than a Gateway path: the owner
# picks the file they just built, on the machine they built it on, and never has
# to know where the Gateway keeps it. The Gateway only ever sees a path inside
# its own staging directory.
LOCAL_BUNDLE="$(/usr/bin/python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("asset_bundle_local") or "")
except Exception:
    print("")
' <<<"$PAYLOAD")"

if [[ -n "$LOCAL_BUNDLE" ]]; then
  if [[ ! -f "$LOCAL_BUNDLE" || "$LOCAL_BUNDLE" != *.zip ]]; then
    echo '{"error":"The asset bundle must be an existing .zip file on this Mac."}'
    exit 1
  fi
  # Named for its contents, not its origin: two owners importing "scenes.zip"
  # must not overwrite one another's staged bundle mid-compile.
  DIGEST="$(/usr/bin/shasum -a 256 "$LOCAL_BUNDLE" | cut -c1-16)"
  STAGED="calla-assets-$DIGEST.zip"
  REMOTE_HOME="$(ssh "${SSH_OPTS[@]}" "$GATEWAY_SSH" 'printf %s "$HOME"')"
  REMOTE_DIR="$REMOTE_HOME/.openclaw/tutor/asset-bundles"
  ssh "${SSH_OPTS[@]}" "$GATEWAY_SSH" "mkdir -p -m 700 '$REMOTE_DIR'"
  scp -q "${SSH_OPTS[@]}" "$LOCAL_BUNDLE" "$GATEWAY_SSH:$REMOTE_DIR/$STAGED"
  ssh "${SSH_OPTS[@]}" "$GATEWAY_SSH" "chmod 600 '$REMOTE_DIR/$STAGED'"
  PAYLOAD="$(/usr/bin/python3 -c '
import json, sys
payload = json.load(sys.stdin)
payload.pop("asset_bundle_local", None)
payload["asset_bundle"] = sys.argv[1]
print(json.dumps(payload, separators=(",", ":")))
' "$REMOTE_DIR/$STAGED" <<<"$PAYLOAD")"
fi

REQUEST="$(/usr/bin/python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(json.dumps({"version": 1, "command": sys.argv[1], "payload": payload}, separators=(",", ":")))
' "$COMMAND" <<<"$PAYLOAD")"

printf '%s\n' "$REQUEST" | ssh "${SSH_OPTS[@]}" \
  "$GATEWAY_SSH" "\$HOME/.local/bin/calla-course"
