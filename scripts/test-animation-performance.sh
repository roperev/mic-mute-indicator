#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 1 || $# -gt 4 || ( $# -eq 4 && "$4" != "--presets" ) ]]; then
  echo "Usage: $0 <matrix-serial> [seconds-per-scenario=8] [output=build/animation-performance.json] [--presets]" >&2
  exit 2
fi
APP="build/Teams Mute Light.app/Contents/MacOS/TeamsMuteLight"
if [[ ! -x "$APP" ]]; then
  echo "Build the app with bash build.sh first." >&2
  exit 2
fi
OUTPUT="${3:-build/animation-performance.json}"
# The app's matrix output must be disabled/closed to release exclusive serial access.
"$APP" --cli animation-benchmark "${2:-8}" "$1" > "$OUTPUT"
python3 - "$OUTPUT" "${4:-}" <<'PY'
import json
import sys

with open(sys.argv[1]) as source:
    rows = json.load(source)
expected = {
    "disabled-pulse", "matrix-solid", "matrix-pulse-1hz", "matrix-flash-1hz",
    "matrix-flash-10hz", "matrix-afk-solid", "matrix-shrug-solid", "locked-matrix-pulse",
}
assert len(rows) == len(expected) and {r["scenario"] for r in rows} == expected
for row in rows:
    seconds = row["seconds"]
    usb = row["usb"]
    assert seconds >= 3 and row["cpuSeconds"] >= 0
    assert row["animationTicks"] <= seconds * 27, row
    assert usb["acknowledgedFrames"] <= seconds * 27, row
    assert usb["transportTicks"] <= seconds * 1.5, row
    fps = usb["acknowledgedFrames"] / seconds
    if row["scenario"] in ("disabled-pulse", "locked-matrix-pulse"):
        assert usb["acknowledgedFrames"] == usb["transmittedBytes"] == 0, row
        assert row["animationTicks"] == usb["transportTicks"] == usb["discoveries"] == 0, row
    elif row["scenario"] == "matrix-solid":
        assert row["animationTicks"] == 0 and 0.5 <= fps <= 1.5, row
    else:
        assert usb["acknowledgedFrames"] > 0, row
    if len(sys.argv) > 2 and sys.argv[2] == "--presets":
        assert row["animationTicks"] == 0, row
        assert usb["discoveries"] == 0, row
        if row["scenario"] not in ("disabled-pulse", "locked-matrix-pulse"):
            assert 0.5 <= fps <= 1.5 and usb["transmittedBytes"] / seconds < 20, row
    print(f'{row["scenario"]:24} CPU={row["cpuPercentOfOneCore"]:.3f}% '
          f'ticks/s={row["animationTicks"]/seconds:.2f} '
          f'USB-fps={fps:.2f} bytes/s={usb["transmittedBytes"]/seconds:.0f} '
          f'transport-ticks/s={usb["transportTicks"]/seconds:.2f} '
          f'discoveries/s={usb["discoveries"]/seconds:.2f}')
print(f'Animation/transport assertions passed; full measurements: {sys.argv[1]}')
PY
