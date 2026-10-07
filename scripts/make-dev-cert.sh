#!/usr/bin/env bash
# One-time: create the self-signed "Shout Dev" code-signing certificate in your login
# keychain, so every build of Shout has the same signature and macOS keeps its
# Accessibility and Microphone permissions across rebuilds.
#
# What it changes: adds one certificate + private key named "Shout Dev" to the login
# keychain, usable by /usr/bin/codesign without a prompt. Nothing else. To undo:
#   security delete-identity -c "Shout Dev" ~/Library/Keychains/login.keychain-db
#
# On a company-managed Mac, check with IT before running this.
set -euo pipefail

NAME="Shout Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl  # macOS's LibreSSL: its PKCS#12 output is what `security import` expects

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in your login keychain. Nothing to do."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# Throwaway password for the temporary .p12 bundle. (Not `tr </dev/urandom | head`: with
# pipefail, tr's SIGPIPE when head stops reading aborts the script silently.)
PASS="$("$OPENSSL" rand -hex 16)"

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASS"

security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
echo "Created \"$NAME\" in your login keychain."
echo "Next: make install   (then grant Accessibility and Microphone one last time)"
