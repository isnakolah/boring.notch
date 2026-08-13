#!/usr/bin/env bash
# Private Gateway updater. No host picker or public-route fallback. `--staged`
# serves Xcode Debug; `--bundle` serves immutable artifact inside installed Boring.
set -euo pipefail

mode="${1:-}"
if [[ "$mode" != "--staged" && "$mode" != "--bundle" ]] || [[ -z "${2:-}" ]]; then
  echo "usage: $0 (--staged|--bundle) <calla-gateway.tar.gz>" >&2
  exit 2
fi
artifact="$2"
[[ -f "$artifact" ]] || { echo "missing artifact: $artifact" >&2; exit 2; }
tar -tzf "$artifact" | /usr/bin/grep -Fxq 'release/manifest.json' || { echo "artifact must contain release/manifest.json" >&2; exit 2; }

gateway="${CALLA_GATEWAY_SSH:-isnakolah@nomonhomelab}"
release_digest="$(tar -xOf "$artifact" release/manifest.json | /usr/bin/python3 -c '
import json, sys
value = json.load(sys.stdin).get("gatewayDigest", "")
if not isinstance(value, str) or len(value) != 64 or any(char not in "0123456789abcdef" for char in value.lower()):
    raise SystemExit("invalid gatewayDigest in release manifest")
print(value)
')"
digest="$(shasum -a 256 "$artifact" | awk '{print $1}')"
remote_root='~/.openclaw/apps/calla-tutor'
remote_archive="$remote_root/incoming/$digest.tar.gz"
remote_preflight=$'set -euo pipefail\nroot=~/.openclaw/apps/calla-tutor\nexpected='"$release_digest"$'\nrelease_name() { [[ -L "$1" ]] && basename "$(readlink -f "$1")" || true; }\nif [[ -f "$root/current/manifest.json" ]] && grep -Fq "\\\"gatewayDigest\\\": \\\"$expected\\\"" "$root/current/manifest.json"; then\n  printf "CALLA_GATEWAY_RESULT\\tunchanged\\t%s\\t%s\\n" "$(release_name "$root/current")" "$(release_name "$root/previous")"\n  exit 0\nfi\nexit 42\n'
set +e
preflight_output="$(ssh "$gateway" "$remote_preflight")"
preflight_status=$?
set -e
if [[ "$preflight_status" == 0 ]]; then
  printf '%s\n' "$preflight_output"
  exit 0
fi
if [[ "$preflight_status" != 42 ]]; then
  printf '%s\n' "$preflight_output" >&2
  exit "$preflight_status"
fi
ssh "$gateway" "umask 077; mkdir -p $remote_root/incoming $remote_root/receipts"
scp "$artifact" "$gateway:$remote_archive"
ssh "$gateway" /bin/bash -s -- "$remote_archive" "$digest" <<'REMOTE_SCRIPT'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin"

root="$HOME/.openclaw/apps/calla-tutor"
archive="$1"
expected="$2"
release_name() { [[ -L "$1" ]] && basename "$(readlink -f "$1")" || true; }
emit_result() { printf "CALLA_GATEWAY_RESULT\\t%s\\t%s\\t%s\\n" "$1" "$(release_name "$root/current")" "$(release_name "$root/previous")"; }

actual=$(shasum -a 256 "$archive" | awk '{print $1}')
test "$actual" = "$expected"
stage=$(mktemp -d "$root/incoming/.stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
tar -xzf "$archive" -C "$stage"
if [[ -f "$root/current/manifest.json" ]] && cmp -s "$stage/release/manifest.json" "$root/current/manifest.json"; then
  echo "Gateway release unchanged"
  emit_result unchanged
  exit 0
fi
config=$(openclaw config file | tail -1)
python3 "$stage/release/bin/calla_gateway_release.py" --staged "$stage/release" --config "$config" --root "$root"
emit_result updated
REMOTE_SCRIPT
echo "Gateway $mode update complete: $digest"
