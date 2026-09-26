#!/usr/bin/env bash
# Creates a self-signed code-signing certificate in the login keychain.
#
#   scripts/create-signing-cert.sh ["Certificate Name"]
#
# Signing every build with the same certificate lets macOS keep the Accessibility permission
# across rebuilds and updates (ad-hoc signatures change with every build). It does not make the
# app trusted by Gatekeeper; that requires an Apple Developer ID and notarization.
#
# build-app.sh picks up a certificate named "HibiVo Self-Signed" automatically.
# macOS will ask for your login password to trust the certificate for code signing.
set -euo pipefail

NAME="${1:-HibiVo Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 file that `security import` accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

# -T lets codesign use the private key without a keychain prompt on every build.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
echo "Trusting the certificate for code signing (macOS will ask for your password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created \"$NAME\"."
echo "build-app.sh will use it automatically. Re-grant Accessibility once after the next build."
