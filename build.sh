#!/usr/bin/env bash
# Build "Teams Mute Light.app" from the Swift package.
#
#   ./build.sh              build into ./build/
#   ./build.sh --install    build and copy to /Applications (recommended for launch-at-login)
#   ./build.sh --run        build and launch
#
# Signing (matters for the Accessibility permission):
#   1. $SIGN_IDENTITY if set
#   2. else the "TeamsMuteLight Local" identity from scripts/create-signing-cert.sh (recommended)
#   3. else ad-hoc. Ad-hoc signatures change on every build, so on --install we reset this app's
#      stale Accessibility entry and you must grant it again after each rebuild.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Teams Mute Light"
EXEC="TeamsMuteLight"
BUNDLE_ID="com.eroper.TeamsMuteLight"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
LOCAL_IDENTITY="TeamsMuteLight Local"

INSTALL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

command -v swift >/dev/null || { echo "swift not found. Install Xcode or run: xcode-select --install" >&2; exit 1; }

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  if security find-certificate -c "$LOCAL_IDENTITY" >/dev/null 2>&1; then
    SIGN_IDENTITY="$LOCAL_IDENTITY"
  else
    SIGN_IDENTITY="-"
  fi
fi

echo "==> Compiling (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$EXEC"

echo "==> Assembling $APP"
HELPER="build/FirmwareTools/MicMatrixFlasher"
if [[ ! -x "$HELPER" || ! -f Resources/Firmware/manifest.json || ! -f Resources/Firmware/micmatrix.bin ]]; then
  echo "Missing bundled firmware/helper. Run the developer preparation scripts in tools/firmware first." >&2
  exit 1
fi
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/$EXEC"
cp Resources/Info.plist "$APP/Contents/Info.plist"
ditto Resources/Firmware "$APP/Contents/Resources/Firmware"
cp "$HELPER" "$APP/Contents/Helpers/MicMatrixFlasher"

echo "==> Signing (identity: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID.flasher" "$APP/Contents/Helpers/MicMatrixFlasher"
shasum -a 256 "$APP/Contents/Helpers/MicMatrixFlasher" | awk '{print $1}' > "$APP/Contents/Resources/Firmware/helper-sha256.txt"
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP/Contents/Helpers/MicMatrixFlasher"
codesign --verify --strict "$APP"
echo "    designated requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"

if [[ $INSTALL -eq 1 ]]; then
  DEST="/Applications/$APP_NAME.app"
  echo "==> Installing to $DEST"
  if [[ -d "$DEST" ]]; then
    osascript -e 'tell application "Teams Mute Light" to quit'
  fi
  sleep 0.5
  if ps -axo comm | grep -Fx "$DEST/Contents/MacOS/$EXEC"; then
    echo "The app is still running (possibly protecting a firmware operation). Installation stopped." >&2
    exit 1
  fi
  ditto "$APP" "$DEST"
  APP="$DEST"
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc build: clearing stale Accessibility entry for $BUNDLE_ID"
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "    Grant Accessibility again from the app (Settings > General > Grant…)."
    echo "    Tip: run scripts/create-signing-cert.sh once so grants survive rebuilds."
  fi
fi

echo "Built: $APP"
echo "CLI:   \"$APP/Contents/MacOS/$EXEC\" --cli devices"

if [[ $RUN -eq 1 ]]; then
  open "$APP"
fi
