#!/usr/bin/env bash
# Creates a local self-signed code-signing certificate named "DisplayControl Local Dev" in your login keychain,
# so rebuilt copies of the app keep their Accessibility permission. Local use only; nothing is uploaded.
set -euo pipefail
NAME="DisplayControl Local Dev"
if security find-identity -p codesigning | grep -q "$NAME"; then echo "Already exists."; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/cs.cnf" <<EOF
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/cs.cnf"
PW="tmp-$RANDOM-$RANDOM"
openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/dc.p12" -name "$NAME" -passout "pass:$PW"
security import "$T/dc.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PW" -T /usr/bin/codesign
echo "Created. macOS lists it as untrusted, which is fine for signing."
