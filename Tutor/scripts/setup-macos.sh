#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_ONLY=0
SKIP_TESTS=0
INSTALL_CALLA_NODE=0
ALLOW_NON_MACOS=0

usage() {
  cat <<'EOF'
Usage: ./scripts/setup-macos.sh [options]

Prepare the current Calla developer build for testing on a Mac. The default run
creates a Python virtual environment, runs tests, compiles the Blender App Pack,
and packages the optional read-only diagnostic add-on. `--install` also starts
the native TutorHost and private OpenClaw node.

Options:
  --check-only                 Check prerequisites without installing or building
  --skip-tests                 Build artifacts without running the test suites
  --install                    Build, install, and connect the complete Calla Mac side
  --install-calla-node         Configure the Calla node and connect through private Tailscale
  --install-openclaw-plugin    Backward-compatible alias for --install-calla-node
  --allow-non-macos            CI/developer override for checking the script on Linux
  -h, --help                   Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    --install|--install-calla-node|--install-openclaw-plugin) INSTALL_CALLA_NODE=1 ;;
    --allow-non-macos) ALLOW_NON_MACOS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

step() {
  printf '\n[%s/5] %s\n' "$1" "$2"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

command_version() {
  local command_name="$1"
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '  %-10s %s\n' "$command_name" "$(command "$command_name" --version 2>/dev/null | head -n 1)"
  else
    printf '  %-10s missing\n' "$command_name"
    return 1
  fi
}

step 1 "Confirming the current Calla test boundary"
cat <<'EOF'
This installer builds the Blender 5.2 App Pack, starts the native local
TutorHost, and connects the Calla node through the private Tailscale Gateway.
No OpenClaw login token or hand-edited configuration is needed for the default
path. macOS will still ask for Accessibility permission.
EOF

platform="$(uname -s)"
if [[ "$platform" != "Darwin" && "$ALLOW_NON_MACOS" -ne 1 ]]; then
  fail "this setup path requires macOS; use --allow-non-macos only for CI validation"
fi
printf 'Platform: %s\n' "$platform"

step 2 "Checking prerequisites"
missing=0
for required_command in git make python3 node npm; do
  command_version "$required_command" || missing=1
done
[[ "$missing" -eq 0 ]] || fail "install the missing prerequisites and run this script again"

python3 - <<'PY' || fail "Python 3.11 or newer is required"
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY

if command -v swift >/dev/null 2>&1; then
  command_version swift
else
  printf '  %-10s %s\n' "swift" "missing (TutorKit tests will be skipped; install Xcode Command Line Tools)"
fi
if command -v openclaw >/dev/null 2>&1; then
  command_version openclaw
else
  printf '  %-10s %s\n' "openclaw" "not installed locally (optional for pack/bridge testing)"
fi
if [[ -d /Applications/Blender.app ]]; then
  printf '  %-10s %s\n' "Blender" "/Applications/Blender.app"
else
  printf '  %-10s %s\n' "Blender" "not found in /Applications (install Blender 5.2.x to test the pack)"
fi

if [[ "$INSTALL_CALLA_NODE" -eq 1 ]]; then
  for required_command in openclaw tailscale xcrun; do
    command -v "$required_command" >/dev/null 2>&1 || fail "--install requires $required_command on this Mac"
  done
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  printf '\nPrerequisite check complete. No files or application settings were changed.\n'
  exit 0
fi

step 3 "Preparing the local Python environment"
cd "$REPOSITORY_ROOT"
if [[ ! -x .venv/bin/python ]]; then
  python3 -m venv .venv
fi
.venv/bin/python -m pip install -e .

step 4 "Building and validating Calla foundations"
if [[ "$SKIP_TESTS" -eq 1 ]]; then
  make PYTHON="$REPOSITORY_ROOT/.venv/bin/python" pack-check pack-build blender-addon
else
  make PYTHON="$REPOSITORY_ROOT/.venv/bin/python" test pack-build blender-addon
fi
if command -v swift >/dev/null 2>&1; then
  swift test --package-path packages/swift/TutorKit
fi

if [[ "$INSTALL_CALLA_NODE" -eq 1 ]]; then
  # Before the LaunchAgents, so the agent finds an installed bundle rather than
  # building one on its first run.
  "$REPOSITORY_ROOT/scripts/build-tutor-host-app.sh" --build-only
  "$REPOSITORY_ROOT/scripts/bootstrap-calla-mac.sh" --install --yes
fi

step 5 "Ready to teach"
cat <<EOF
Keep the application you want taught focused. \`--install\` has already built
and installed Calla TutorHost.app and started the Calla node over private
Tailscale WSS; no Gateway login or node ID is required, and the Gateway enrols
this Mac automatically.

One macOS permission is required, and it is the only one the screenshot path
needs: approve Calla TutorHost under
  System Settings > Privacy & Security > Screen & System Audio Recording

Then check the whole teaching path locally:
  $REPOSITORY_ROOT/.venv/bin/python $REPOSITORY_ROOT/tools/calla_guide_probe.py --bundle-id org.blenderfoundation.blender

For optional read-only bridge diagnostics, install the generated add-on from
Blender's Add-ons preferences, then run:
  $REPOSITORY_ROOT/.venv/bin/python $REPOSITORY_ROOT/tools/blender_bridge_probe.py --operation observe_state
EOF
