#!/bin/bash
# Build AgentDeck.app with SwiftPM (no Xcode needed). Signs with the local identity from
# make_signing_identity.sh when it exists, so macOS permission grants survive rebuilds; ad hoc otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product AgentDeck
bin="$(swift build -c release --show-bin-path)/AgentDeck"

app=build/AgentDeck.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/AgentDeck"
cp Resources/Info.plist "$app/Contents/Info.plist"

signing="$HOME/Library/Application Support/agent-deck/signing"
keychain="$signing/agent-deck-signing.keychain-db"
if [ -f "$keychain" ]; then
    security unlock-keychain -p "$(cat "$signing/keychain-password")" "$keychain"
    identity="$(security find-identity -p codesigning "$keychain" | awk '/AgentDeck Local Signing/ {print $2; exit}')"
    # codesign refuses the identity until its certificate is trusted for code signing (a one-time user step).
    codesign --force --keychain "$keychain" --sign "$identity" "$app" 2>/dev/null \
        || { echo "local identity not trusted yet; signing ad hoc" >&2; codesign --force --sign - "$app"; }
else
    codesign --force --sign - "$app"
fi
echo "$app"
