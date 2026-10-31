#!/bin/zsh
# One-time setup: creates a local code-signing certificate ("ArcSidebar Local Signing") in your
# login keychain, so macOS keeps proDOCKtivity's permissions (Accessibility, Arc control)
# across rebuilds. Run it yourself in Terminal; it asks for your Mac password once (to trust it).
set -euo pipefail
NAME="ArcSidebar Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "“$NAME” already exists. Nothing to do."
  exit 0
fi

# Use the Mac's own OpenSSL: newer versions (e.g. Homebrew's) write files the keychain can't read.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:temp 2>/dev/null

security import "$TMP/id.p12" -k "$KEYCHAIN" -P temp -T /usr/bin/codesign
echo "Now macOS asks for your password to trust the certificate for code signing…"
if ! security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  echo "(Couldn't mark it as trusted. That's usually fine; signing works without it.)"
fi

echo
if security find-identity -p codesigning | grep -q "$NAME"; then
  echo "Done. Now run ./scripts/build-app.sh."
else
  echo "Something went wrong: the certificate isn't there. Check the output above."
fi
