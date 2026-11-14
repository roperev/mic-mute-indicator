#!/usr/bin/env bash
# Render current Settings views using isolated sample configuration, not personal preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/test-settings-window.sh
APP="build/Settings Screenshots.app"
mkdir -p "$APP/Contents/MacOS" Resources/screenshots
cp build/settings-window-tests "$APP/Contents/MacOS/TeamsMuteLight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
"$APP/Contents/MacOS/TeamsMuteLight" --screenshots --capture --light
for tab in 0 1 2 3; do
  case "$tab" in
    0) name=general ;;
    1) name=lights ;;
    2) name=effects ;;
    3) name=advanced ;;
  esac
  cp "build/settings-light-tab-$tab.png" "Resources/screenshots/$name.png"
done
cp build/settings-light-color-popover.png Resources/screenshots/color-picker.png
