#!/usr/bin/env bash
# LaunchAgent entrypoint for the local native TutorHost.
#
# This execs the binary inside "Calla TutorHost.app" rather than `swift run`.
# Screen Recording is granted to an application identity, and running the loose
# build product hands macOS a different path and code hash on every rebuild, so
# the grant could never stick and the overlay renderer — which ships nested in
# the bundle — could not be found at all.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIRECTORY/.." && pwd)"
APP="${CALLA_APP_DESTINATION:-$HOME/Applications}/Calla TutorHost.app"
HOST_BINARY="$APP/Contents/MacOS/CallaTutorHost"

if [[ ! -x "$HOST_BINARY" ]]; then
  echo "Calla TutorHost.app is not installed; building it now." >&2
  "$SCRIPT_DIRECTORY/build-tutor-host-app.sh" --build-only >&2 || {
    echo "Could not build Calla TutorHost.app from $REPOSITORY_ROOT" >&2
    exit 78
  }
fi

SOCKET_DIRECTORY="$HOME/Library/Application Support/CallaTutor"
mkdir -p "$SOCKET_DIRECTORY"
chmod 700 "$SOCKET_DIRECTORY"

exec "$HOST_BINARY"
