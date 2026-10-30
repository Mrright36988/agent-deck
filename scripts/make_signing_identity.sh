#!/bin/bash
# One-time setup: a self-signed code-signing identity in a keychain of its own, so that the
# Accessibility and Notification grants survive rebuilds (ad-hoc signatures change every build).
# The login keychain and the keychain search list are left untouched; build_app.sh passes --keychain.
set -euo pipefail

dir="$HOME/Library/Application Support/agent-deck/signing"
keychain="$dir/agent-deck-signing.keychain-db"
name="AgentDeck Local Signing"

mkdir -p "$dir" && chmod 700 "$dir"
[ -f "$dir/keychain-password" ] || /usr/bin/openssl rand -hex 24 > "$dir/keychain-password"
chmod 600 "$dir/keychain-password"
password="$(cat "$dir/keychain-password")"

if [ ! -f "$keychain" ]; then
    security create-keychain -p "$password" "$keychain"
    security set-keychain-settings "$keychain"
fi
security unlock-keychain -p "$password" "$keychain"

if ! security find-identity -p codesigning "$keychain" | grep -q "$name"; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/req.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
        -out "$tmp/identity.p12" -passout "pass:$password"
    security import "$tmp/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$keychain" >/dev/null
fi

security find-identity -p codesigning "$keychain"
