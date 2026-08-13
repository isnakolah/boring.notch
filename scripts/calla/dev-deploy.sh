#!/usr/bin/env bash
# Debug-only Tutor Gateway staging. Gateway update remains private-SSH only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TUTOR="$ROOT/Tutor"
ARTIFACT_DIRECTORY="${TMPDIR:-/tmp}/boring-calla-artifact"
RELEASE_DIRECTORY="$ARTIFACT_DIRECTORY/release"
ARTIFACT="$ARTIFACT_DIRECTORY/calla-gateway.tar.gz"
CACHE_DIRECTORY="$HOME/Library/Application Support/boringNotch/Calla"
CACHE_FILE="$CACHE_DIRECTORY/debug-gateway-source.sha256"
mkdir -p "$ARTIFACT_DIRECTORY"

# Source digest deliberately excludes build products. It is the Debug release
# identity, so a changed working tree can never overwrite a different staged
# release with the same short Git SHA.
SOURCE_DIGEST="$(find "$TUTOR" -type f \
  ! -path '*/.build/*' ! -path '*/.venv/*' ! -path '*/node_modules/*' ! -path '*/__pycache__/*' ! -path '*/build/*' -print0 \
  | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
if [[ -f "$CACHE_FILE" && "$(<"$CACHE_FILE")" == "$SOURCE_DIGEST" ]]; then
  echo "Tutor Gateway source unchanged; skipping checks, upload, and Gateway update."
  exit 0
fi

PYTHON_BIN="${PYTHON:-$TUTOR/.venv/bin/python}"
if [[ ! -x "$PYTHON_BIN" ]]; then PYTHON_BIN="${PYTHON:-python3}"; fi
"$PYTHON_BIN" -c 'import yaml' 2>/dev/null \
  || { echo "Tutor pack dependencies missing; create Tutor/.venv and install Tutor/pyproject.toml." >&2; exit 78; }
make -C "$TUTOR" PYTHON="$PYTHON_BIN" pack-check openclaw-test pack-build
VERSION="debug-$(git -C "$ROOT" rev-parse --short HEAD)-${SOURCE_DIGEST:0:12}"
PYTHONPATH="$TUTOR/Gateway/installer" "$PYTHON_BIN" "$TUTOR/Gateway/installer/build_release.py" \
  --tutor "$TUTOR" --output "$RELEASE_DIRECTORY" --version "$VERSION"
tar -C "$ARTIFACT_DIRECTORY" -czf "$ARTIFACT" release
DIGEST="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
echo "Tutor Gateway artifact: $ARTIFACT"
echo "sha256: $DIGEST"
"$ROOT/scripts/calla/gateway-update.sh" --staged "$ARTIFACT"
mkdir -p "$CACHE_DIRECTORY"
chmod 700 "$CACHE_DIRECTORY"
printf '%s\n' "$SOURCE_DIGEST" >"$CACHE_FILE"
chmod 600 "$CACHE_FILE"
echo "Gateway staged update installed."
