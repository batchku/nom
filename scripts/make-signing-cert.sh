#!/bin/bash
# One-time setup: create a self-signed "nom-dev" codesigning certificate so
# TCC permission grants (Accessibility) survive rebuilds. build-app.sh uses
# it automatically when present.
set -euo pipefail

if security find-identity -v -p codesigning 2>/dev/null | grep -q "nom-dev"; then
    echo "nom-dev identity already exists"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/nomdev.key" -out "$TMP/nomdev.crt" \
    -days 3650 -nodes -subj "/CN=nom-dev" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"

# -legacy: security(1) can't read OpenSSL 3's default PKCS12 encryption
openssl pkcs12 -export -legacy -out "$TMP/nomdev.p12" -inkey "$TMP/nomdev.key" \
    -in "$TMP/nomdev.crt" -passout pass:nomdev -name "nom-dev"

security import "$TMP/nomdev.p12" -k ~/Library/Keychains/login.keychain-db \
    -P nomdev -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/nomdev.crt"

security find-identity -v -p codesigning | grep "nom-dev"
echo "done — build-app.sh will now sign with nom-dev"
