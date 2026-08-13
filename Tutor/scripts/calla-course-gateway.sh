#!/usr/bin/env bash
# Gateway half of `calla-course.sh`. stdin/stdout only; socket stays owner-only.
set -euo pipefail
SOCKET="${CALLA_COURSE_SOCKET:-$HOME/.openclaw/tutor/course-control.sock}"
exec /usr/bin/python3 -c '
import socket, sys
request = sys.stdin.buffer.read()
if not request or len(request) > 131072:
    raise SystemExit("invalid course request")
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(15)
s.connect(sys.argv[1])
s.sendall(request)
s.shutdown(socket.SHUT_WR)
while True:
    chunk = s.recv(65536)
    if not chunk: break
    sys.stdout.buffer.write(chunk)
' "$SOCKET"
