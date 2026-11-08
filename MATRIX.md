# Waveshare matrix guide

[Back to README](README.md#hardware-and-outputs)

## Hardware and safety

The [ESP32-S3-Matrix](https://docs.waveshare.com/ESP32-S3-Matrix) has 64 addressable RGB LEDs on GPIO 14 and a QMI8658 accelerometer on SDA 11 / SCL 12. Native USB CDC provides the connection; Wi-Fi, Bluetooth and the gyroscope are unused.

The tested board uses **RGB**, not the font example's GRB order. Pixel wiring is top-right, progressive columns: `(7 - column) * 8 + row`.

| Brightness control | Value |
|---|---|
| New-install master | **9.0%**, intended for a diffusing case |
| Master slider | **1-10%** |
| Firmware nonzero floor | `3/255` |
| Firmware maximum | `25/255`, approximately **9.8%** |
| Editable status multipliers | **0-100%** of master |
| CLI hardware demos | **5%**, independent of saved master |

**Waveshare warns that excessive brightness can damage the board.** A case may reduce perceived light without reducing heat. Begin around 2% for exposed LEDs, avoid sustained full-panel white, and unplug unusually hot hardware. The ceiling is a precaution, not a thermal guarantee.

Gamma-2.2 converts display-encoded colors to linear LED intensities. Relative status gain is applied afterward; firmware then scales every channel by master PWM. Relative dimming can go below the master's floor, and zero remains off. Eight-bit precision can hide weak channels or cause color steps. On-screen previews show normalized source colors, not physical output.

## Build and flash

Install Arduino CLI with `brew install arduino-cli`. The pinned profile uses ESP32 Arduino core **3.3.12**, Adafruit NeoPixel **1.15.5**, and SensorLib **0.5.1**.

```bash
arduino-cli compile --profile matrix --output-dir build/firmware firmware/MicMatrix
arduino-cli board list
```

The first profile build downloads dependencies. Native hardware USB CDC is enabled; flash size is 4 MiB and PSRAM is disabled.

### Back up before replacing firmware

Disable the app's matrix output and close all serial monitors. Flashing replaces the board's current program. Original images may contain credentials: store them **outside Git**.

```bash
ESPTOOL="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"
PORT="/dev/cu.usbmodem11401"   # use the current discovered port
BACKUP="$HOME/Library/Application Support/TeamsMuteLight/FirmwareBackups"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
# Choose a fresh filename; never overwrite an original backup.
"$ESPTOOL" --chip esp32s3 --port "$PORT" read-flash 0 ALL "$BACKUP/original.bin"
chmod 600 "$BACKUP/original.bin"
shasum -a 256 "$BACKUP/original.bin"
"$ESPTOOL" --chip esp32s3 --port "$PORT" verify-flash 0 "$BACKUP/original.bin"
# Proceed only after a complete, verified 4 MiB backup.
arduino-cli upload --profile matrix --port "$PORT" --input-dir build/firmware firmware/MicMatrix
```

For download mode, hold BOOT, press/release RESET, then release BOOT and select the new port. Press RESET if the program does not start after upload.

Restore a verified original with:

```bash
"$ESPTOOL" --chip esp32s3 --port "$PORT" write-flash 0 "$BACKUP/original.bin"
```

## App setup and defaults

Enable **Settings > Lights > Waveshare ESP32-S3 Matrix (USB)** and select its USB serial. A selected serial never falls back to another board. The driver verifies the exact firmware handshake and accelerometer health before showing artwork.

Fresh v2.0.1 settings:

| Status | Icon | Original palette | Relative level | Effect |
|---|---|---|---|---|
| Live | Dot | Yes | 100% | Pulse at 1 Hz |
| Muted | Muted microphone | Yes | 75% | Solid |
| Not in meeting | Adobe A | Yes | 20% | Solid |

Master is 9.0%. Palette intensity is full for all three; the multipliers provide dimming. Existing saved settings remain intact. Pre-relative-brightness settings retain 100% gains.

Unavailable is a fixed red ! with yellow accents, at master brightness. It is not editable, but Warning remains selectable for other statuses. It means unknown detection, not Teams presence.

### Artwork and effects

The [gallery](Resources/matrix-gallery.svg) has 16 choices and 48 previews:

The default gallery is static. The [animated gallery](Resources/matrix-gallery-animated.svg) is a separate, opt-in view; it can be GPU-intensive. `generate-matrix-gallery.sh` regenerates both versions from the same artwork. Static AFK shows A; static Shrug shows its central glyphs rather than an empty first frame.

Microphone, Muted microphone, Fire, No sign, Check, Dot, Orientation arrow, Warning, Heart, Adobe A, Rainbow, Headphones, Moon, AFK, Smiley, Shrug.

- **Original palette:** preserves artwork hue; saved color's strongest channel determines palette gain. Fresh defaults use full gain.
- **Tint artwork:** multiplies RGB channels by the tint; complementary colors may disappear.
- **Single color:** fills the artwork mask with the chosen color.
- **Display / 0%:** hides a status without changing the selected icon.
- **AFK:** A/F/K cycle every 0.8 seconds in cyan/yellow/green.
- **Shrug:** `¯\_(ツ)_/¯` scrolls right-to-left at eight pixels/second, preserving reading order.
- **Adobe A:** a hand-tuned red pixel approximation with shaded edges, not an official asset. Legacy identifier: `shield`.

Animated icons run even with Solid selected. Palette, gamma, brightness and orientation apply to every frame. Hero/chooser previews animate but deliberately do not scale with brightness sliders.

Call start temporarily replaces artwork with a full-panel rippling rainbow wash. It uses master brightness and restores the status after the configured duration. The manual Rainbow Sweep can add a dark lead-in. Other USB outputs retain single-color sweeps.

### Lock and sleep

When detection is neither Live nor Muted, macOS screen lock, inactive session, display sleep or system sleep blanks the matrix. Returning to an unlocked, active, awake session restores it. No separate idle timer or Settings toggle is used.

Actual call states are exempt from lock/display-sleep blanking. During system sleep, USB updates stop and the watchdog clears stale output regardless. Previews and rainbow tests cannot override no-call automatic blanking. Other outputs keep their existing behavior.

## Orientation and connection

Gravity is filtered at 25 Hz; quadrant changes must remain stable for 200 ms. Hysteresis avoids diagonal flicker. Flat poses, free fall and large accelerations retain the last orientation. Stale or unavailable IMU data blanks the board and reports an error.

Mapping: positive/negative X selects turns 3/1; positive/negative Y selects 0/2. A fixed 180-degree mounting correction is applied before the user offset. Mirror calibration also adjusts rotation handedness.

The Orientation icon has an upward arrow and lower-left dot. Use it to check all four upright positions; offset and mirror controls are under **Orientation calibration**.

Serial I/O is nonblocking on a private queue. Exclusive access, partial writes, frame coalescing, acknowledgements and reconnect protect the UI and transport. Solid frames are refreshed at least once a second. Firmware starts dark, accepts explicit Off, and clears after three seconds without valid display updates.

## CLI demos

Disable matrix output in the running app before using the CLI. Demos use 5%, not the new-install 9% master.

```bash
APP="/Applications/Teams Mute Light.app/Contents/MacOS/TeamsMuteLight"
"$APP" --cli devices
"$APP" --cli matrix-probe
"$APP" --cli matrix-test
"$APP" --cli matrix-rainbow
"$APP" --cli matrix heart "#FFFFFF" 3
"$APP" --cli matrix afk "#FFFFFF" 5
"$APP" --cli matrix shrug "#FFFFFF" 6
"$APP" --cli matrix warning "#FFFFFF" 3
"$APP" --cli matrix shield "#FFFFFF" 3
# Optional serial, clockwise offset 0...3, mirror 0/1, palette color/mono:
"$APP" --cli matrix orientation "#FF0000" 20 "D4:05:92:40:89:A0" 0 0 color
```

CLI `off` remains supported for dark frames. In original palette mode, white means full palette intensity, not white artwork.

## USB protocol v3

115200 baud, ASCII newline-terminated commands:

| Command | Reply |
|---|---|
| `HELLO` | `MATRIX 3 8 8 25`, only with healthy IMU |
| `FRAME seq brightness flags rgb` | `OK seq` |
| `DRAW seq r g b brightness flags bitmap` | `OK seq` |
| `OFF seq` | `OK seq` |
| `STATUS` | `STATE litCount maxRed maxGreen maxBlue` |
| `ORIENTATION` | `ORIENT quadrant x-mg y-mg z-mg upright` |

- Sequence: unsigned 32-bit integer.
- FRAME: exactly 64 `RRGGBB` values, top-left row-major, 384 hex characters.
- DRAW: 16 hex digits; most significant byte is the top row and most significant bit is leftmost.
- RGB/brightness inputs: 0-255. Nonzero brightness is clamped to 3-25; zero stays zero.
- Flags: 0-7; bits 0-1 are clockwise offset, bit 2 is mirror.
- Input line: maximum 448 bytes. USB receive buffer: 1024 bytes.
- STATUS reports scaled output-buffer values, not source artwork.

Parsing is atomic. Malformed input returns `ERR ...` without replacing the display or renewing its watchdog. Timeout blanks LEDs and emits `TIMEOUT`. HELLO, STATUS, ORIENTATION and orientation redraws do not renew the three-second timeout.

The Mac app applies gamma/relative gain before FRAME transmission; firmware scales raw RGB and does not apply gamma again. Older handshake ceilings/protocol versions must be upgraded.

## Validation

```bash
bash scripts/test-matrix.sh
bash scripts/generate-matrix-gallery.sh
bash build.sh
arduino-cli compile --profile matrix --output-dir build/firmware firmware/MicMatrix
# Optional physical tests; close the app's matrix output first:
python3 scripts/test-matrix-hardware.py /dev/cu.usbmodem11401 --app "$APP"
python3 scripts/test-matrix-hardware.py /dev/cu.usbmodem11401 --orientation-test
```

The Swift/C++ tests need no XCTest or full Xcode. Hardware tests check handshake, IMU, busy-port errors, brightness floor/ceiling/zero, relative dimming, gamma-corrected red, watchdog, oversized/malformed input, 25 fps transport and all 64 independent RGB pixels.

Artwork is defined in [MatrixProtocol.swift](Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift); the SVG generator uses the same source pixels. Physical orientation, lock/unlock restoration, call-start restoration, and menu-bar pulsing were also tested interactively.
