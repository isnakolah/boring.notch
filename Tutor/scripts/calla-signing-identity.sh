#!/usr/bin/env bash
# Create the local code-signing identity Calla is signed with.
#
# Screen Recording is granted to an application's code identity. Ad-hoc signing
# has none — macOS falls back to the code hash, which changes on every rebuild,
# so the grant is revoked every single time the host is rebuilt. A certificate,
# even a self-signed one, gives the bundle a designated requirement that names
# the identifier and the certificate rather than the bytes, so one approval
# survives rebuilds.
#
# No Apple Developer account and no sudo. Everything lives in the login keychain
# and can be removed in Keychain Access, or with --remove.
set -euo pipefail

IDENTITY_NAME="${CALLA_SIGNING_IDENTITY:-Calla Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
MODE=ensure

usage() {
  cat <<'EOF'
Usage: ./scripts/calla-signing-identity.sh [--ensure | --status | --remove]

  --ensure   Create the identity if it does not exist yet (default)
  --status   Report whether the identity exists
  --remove   Delete the identity from the login keychain

Environment:
  CALLA_SIGNING_IDENTITY   Common name to use (default: "Calla Local Signing")
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ensure) MODE=ensure ;;
    --status) MODE=status ;;
    --remove) MODE=remove ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

has_identity() {
  security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1
}

case "$MODE" in
  status)
    if has_identity; then
      echo "present: $IDENTITY_NAME"
    else
      echo "absent: $IDENTITY_NAME"
      exit 1
    fi
    ;;
  remove)
    if has_identity; then
      security delete-certificate -c "$IDENTITY_NAME" -t "$KEYCHAIN"
      echo "Removed $IDENTITY_NAME. Calla will fall back to ad-hoc signing."
    else
      echo "Nothing to remove; $IDENTITY_NAME is not in the login keychain."
    fi
    ;;
  ensure)
    if has_identity; then
      echo "Signing identity already present: $IDENTITY_NAME"
      exit 0
    fi
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    # codeSigning EKU is what lets codesign use this certificate at all.
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
      -subj "/CN=$IDENTITY_NAME/O=Calla/C=US" \
      -addext "basicConstraints=critical,CA:false" \
      -addext "keyUsage=critical,digitalSignature" \
      -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
    openssl pkcs12 -export -out "$WORK/identity.p12" \
      -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
      -name "$IDENTITY_NAME" -passout pass: >/dev/null 2>&1
    # -A so codesign can use the key without prompting for keychain access on
    # every build. The key never leaves this keychain.
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" -A >/dev/null
    echo "Created signing identity: $IDENTITY_NAME"
    echo "Calla is now signed with it, so Screen Recording survives a rebuild."
    echo "Remove it any time with: ./scripts/calla-signing-identity.sh --remove"
    ;;
esac
