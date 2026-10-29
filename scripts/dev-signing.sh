#!/bin/bash
# Creates (once) a self-signed "Localflow Development" code-signing identity in a dedicated
# keychain, and unlocks it for codesign.
#
# Why: ad-hoc signatures change on every build, so macOS forgets the Accessibility and
# Microphone grants after each rebuild. Signing with a stable certificate keeps the app's
# designated requirement (bundle id + certificate) identical across builds.
#
# The keychain is deliberately NOT added to the keychain search list, so nothing else ever
# looks at it or prompts for it. Its password only guards this throwaway dev key.
#
# usage: scripts/dev-signing.sh            # ensure identity exists and is unlocked
#        scripts/dev-signing.sh --remove   # delete the keychain and identity
set -euo pipefail

NAME="Localflow Development"
KEYCHAIN="$HOME/Library/Keychains/localflow-dev.keychain-db"
PASSWORD="localflow-dev"

if [ "${1:-}" = "--remove" ]; then
  security delete-keychain "$KEYCHAIN" 2>/dev/null || rm -f "$KEYCHAIN"
  echo "Removed $KEYCHAIN"
  exit 0
fi

if [ ! -e "$KEYCHAIN" ]; then
  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT
  cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  # /usr/bin/openssl is LibreSSL, whose PKCS#12 defaults are readable by `security import`.
  /usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/id.p12" -passout pass:"$PASSWORD" -name "$NAME"
  security create-keychain -p "$PASSWORD" "$KEYCHAIN"
  security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" </dev/null
  security set-keychain-settings "$KEYCHAIN" </dev/null  # No auto-lock.
  security import "$work/id.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
  echo "Created signing identity \"$NAME\" in $KEYCHAIN"
fi

# Locked again after logout/reboot; unlocking with -p never shows a dialog.
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN" </dev/null
