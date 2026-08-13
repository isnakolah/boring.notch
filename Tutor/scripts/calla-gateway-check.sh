#!/usr/bin/env bash
# Read-only private Gateway health check for TutorHost Settings.
set -euo pipefail

GATEWAY_SSH="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
CONTROL="/tmp/calla-gateway-check.sock"
REMOTE='export PATH="$HOME/.npm-global/bin:$PATH"
if ! command -v openclaw >/dev/null 2>&1; then printf "{\"ok\":false,\"summary\":\"OpenClaw is not installed on Gateway.\"}\n"; exit 0; fi
gateway=false; plugin=false; course=false
timeout 12 openclaw gateway status >/dev/null 2>&1 && gateway=true
# The socket is created only by the activated Gateway plugin; inspection without
# --runtime avoids a slow plugin RPC from making Settings look falsely offline.
timeout 12 openclaw plugins inspect tutor --json >/dev/null 2>&1 && plugin=true
test -S "$HOME/.openclaw/tutor/course-control.sock" && course=true
if [ "$gateway" = true ] && [ "$plugin" = true ] && [ "$course" = true ]; then summary="Gateway reachable. Tutor plugin active. Course control ready."; ok=true; else summary="Gateway reached, but Tutor course control is not ready."; ok=false; fi
printf "{\"ok\":%s,\"gateway\":%s,\"plugin\":%s,\"course_control\":%s,\"summary\":\"%s\"}\n" "$ok" "$gateway" "$plugin" "$course" "$summary"'

exec ssh -o BatchMode=yes -o ConnectTimeout=8 \
  -o ControlMaster=auto -o "ControlPath=$CONTROL" -o ControlPersist=8h \
  "$GATEWAY_SSH" "$REMOTE"
