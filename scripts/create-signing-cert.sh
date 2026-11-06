#!/usr/bin/env bash
# Creates a self-signed code-signing identity "TeamsMuteLight Local" in your login keychain.
#
# Why: macOS ties the Accessibility (TCC) grant to the app's code signature. Ad-hoc signatures
# change on every rebuild, so the grant silently stops matching. A stable certificate keeps the
# grant valid across rebuilds. This cert only signs your own local build; it isn't trusted for
# anything else and never leaves this Mac.
set -euo pipefail

NAME="TeamsMuteLight Local"
OPENSSL=/usr/bin/openssl   # macOS LibreSSL: its .p12 output imports cleanly with `security`
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"

cat > "$TMP/cert.cnf" <<EOF
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

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" >/dev/null 2>&1

# Random one-time password only protects the temp .p12 during import.
P12PASS="$("$OPENSSL" rand -hex 16)"
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -name "$NAME" -out "$TMP/id.p12" -passout "pass:$P12PASS" >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign >/dev/null

echo "Created code-signing identity \"$NAME\"."
echo "build.sh will now use it automatically. The first codesign may ask for your login keychain"
echo "password; click \"Always Allow\"."
