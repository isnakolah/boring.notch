#!/usr/bin/env bash
# Build immutable Gateway artifact bundled with one Boring build. This script
# never contacts Gateway; gateway-update.sh is sole private-SSH transport.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TUTOR="$ROOT/Tutor"
DESTINATION="${1:?usage: build-gateway-release.sh <artifact.tar.gz>}"
if [[ -n "${PYTHON:-}" ]]; then
  PYTHON_BIN="$PYTHON"
elif [[ -x "$TUTOR/.venv/bin/python" ]]; then
  PYTHON_BIN="$TUTOR/.venv/bin/python"
elif command -v uv >/dev/null 2>&1; then
  # `uv run` creates Boring-local Tutor dependencies from pyproject.toml;
  # no retired Calla checkout or virtualenv is consulted.
  PYTHON_BIN=""
else
  echo "missing Tutor Python runtime; install uv or set PYTHON" >&2
  exit 78
fi
mkdir -p "$(dirname "$DESTINATION")"

# Version changes with any Gateway-owned source or pack input. Reusing an
# unchanged digest lets Gateway return without a new transaction.
SOURCE_DIGEST="$(find "$TUTOR" -type f \
  ! -path '*/.build/*' ! -path '*/.venv/*' ! -path '*/node_modules/*' ! -path '*/__pycache__/*' ! -path '*/build/*' -print0 \
  | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
VERSION="boring-${SOURCE_DIGEST:0:20}"
TEMPORARY="$(mktemp -d "${TMPDIR:-/tmp}/calla-gateway-build.XXXXXX")"
trap 'rm -rf "$TEMPORARY"' EXIT

if [[ -n "$PYTHON_BIN" ]]; then
  make -C "$TUTOR" pack-build PYTHON="$PYTHON_BIN" >/dev/null
  "$PYTHON_BIN" "$TUTOR/Gateway/installer/build_release.py" \
    --tutor "$TUTOR" --output "$TEMPORARY/release" --version "$VERSION" >/dev/null
else
  uv run --project "$TUTOR" -- make -C "$TUTOR" pack-build PYTHON=python >/dev/null
  uv run --project "$TUTOR" -- python "$TUTOR/Gateway/installer/build_release.py" \
    --tutor "$TUTOR" --output "$TEMPORARY/release" --version "$VERSION" >/dev/null
fi
# Do not serialize macOS extended-attribute sidecars. GNU tar extracts them as
# `._*` files, which would otherwise alter a valid cross-host release tree.
COPYFILE_DISABLE=1 tar -C "$TEMPORARY" -czf "$DESTINATION" release
chmod 600 "$DESTINATION"
echo "Bundled Calla Gateway release $VERSION"
