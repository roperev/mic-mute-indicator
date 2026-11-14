#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash build.sh
APP="build/Teams Mute Light.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
if [[ $(uname -m) != arm64 ]]; then
  echo "This first firmware-installer release supports Apple Silicon only." >&2
  exit 1
fi
file "$APP/Contents/MacOS/TeamsMuteLight" | grep -q arm64
file "$APP/Contents/Helpers/MicMatrixFlasher" | grep -q arm64
codesign --verify --strict "$APP"
OUTPUT="build/TeamsMuteLight-v${VERSION}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Download artifact: $OUTPUT"
echo "Locally signed, not Apple-notarized. macOS may require explicit user approval."
