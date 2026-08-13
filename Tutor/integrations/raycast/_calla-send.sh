# Shared by the Calla Raycast commands. Not a command itself: Raycast only
# lists files carrying the @raycast metadata header, so this stays hidden.
#
# The actual sending lives in scripts/calla-ask.sh, which the Mac app's own
# tooltip buttons use too. One place decides where a question goes.

calla_send() {
  local here root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "$here/../.." && pwd)"
  "$root/scripts/calla-ask.sh" "$1"
}
