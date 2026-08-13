#!/bin/bash
#
# "I did that — what now?" in one keystroke.
#
# The step Calla is on is the thing you are most likely to want next, and
# retyping a sentence to say you finished it is friction in exactly the wrong
# place. Same lesson, same session as Teach me…
#
# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Next step
# @raycast.mode compact
#
# Optional parameters:
# @raycast.icon 👉
# @raycast.packageName Calla
#
# Documentation:
# @raycast.description Tell Calla you finished the step and have it point at the next one.
# @raycast.author Calla

set -uo pipefail
source "$(dirname "$0")/_calla-send.sh"

calla_send "I did that. Look at the window again and point me at the next step." || exit 1
echo "Calla is checking your screen — switch back to the app."
