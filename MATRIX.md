# Waveshare matrix guide

[Back to README](README.md#hardware-and-outputs)

For **Teams Mute Light v4.0.0** and **MicMatrix wire protocol v4**. App and protocol versions are independent. The app also supports v3 firmware through streamed frames. The packaged Apple Silicon app includes its own MicMatrix image and flashing helper.

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

## Install or restore from the app

The finished `.app` includes the firmware image and standalone flashing helper. End users need no developer tools, Python, Homebrew, Arduino CLI or network connection for flashing. Supported target: **Waveshare ESP32-S3-Matrix, ESP32-S3 with 4 MiB flash**, on Apple Silicon macOS 14+. Intel Macs, other board models and secured/encrypted chips are not supported by this installer.

### Detection and status

Open **General > Matrix firmware** even when the light output is disabled:

| Status | Meaning |
|---|---|
| Green/checkmark | Recognized healthy MicMatrix; protocol and build information are shown when actually known |
| Blue/information | Known original-stock executable fingerprint, or explicitly **Possibly stock — firmware not recognized** when evidence is inconclusive |
| Yellow/warning | Positive alternate/incompatible firmware evidence, hardware errors or an operation needing attention. MicroPython is recognized conservatively from validated executable/DROM runtime signatures; arbitrary nonmatching images remain unrecognized. |
| Bootloader/connection state | Inspection or recovery may need BOOT/RESET; this is not proof of stock or alternate firmware |

A silent USB device is not proof of stock firmware. A matching Espressif vendor/product ID is not proof of the Waveshare board model. An original factory-image fingerprint can recognize that known image, not every vendor batch. Build versions are not invented for old firmware that does not report them.

USB attach/detach observations and bounded handshake checks populate the panel without permanent fast discovery polling. **Inspect firmware** is explicitly disruptive: it resets into download mode, verifies the chip/MAC/flash size and inspects firmware evidence without writing flash.

### Install

1. Select the exact connected board, then Inspect.
2. Choose Install MicMatrix and confirm the physical board is the supported Waveshare model.
3. Keep **Back up current firmware** enabled. The complete 4 MiB image is verified before erasure; a failed backup stops the operation.
4. Keep **Use this matrix for status lights** enabled if desired. Only successful flash verification plus a healthy MicMatrix/IMU check enables/selects output.
5. Do not unplug the board. The app hands off its exclusive serial connection to the bundled helper; unrelated light outputs retain their settings.

The helper checks actual ESP32-S3 identity, flash size and security protections in its connection. It will not force past secure boot/encryption restrictions or write eFuses. It verifies the complete written flash before resetting.

To skip backup, uncheck it and confirm the separate **Erase and install without backup** warning. This destroys existing flash contents and does not create an original to restore. The next install defaults to backup again. Existing originals are never deleted or replaced by this opt-out.

### Original backups and restore

Default location:

```text
~/Library/Application Support/TeamsMuteLight/FirmwareBackups/<device-MAC>/
```

The panel shows the verified original's path, checksum status and Reveal in Finder action. Backups have restrictive local permissions. Partial/unverified images are not restore choices. Originals are not overwritten by later MicMatrix snapshots or app updates, and are not included in Git, app downloads or public logs.

**Flash back to original firmware…** writes this exact board's captured full flash image back onto the board. If that image contained alternate firmware, that is what it returns to; it is not automatically “factory stock.” No generic stock image is bundled.

**Choose an existing backup file…** registers a file from disk for the inspected board; it does not flash or change the board. If no original is registered, the confirmed file becomes its original backup. Otherwise it is added separately and the original is unchanged. Size/header/checksum checks do not prove which device produced a raw file; do not choose another board's image. If backup was skipped and no original exists, flashing back is unavailable.

Restore has a separate destructive confirmation. Successful restore requires full verification before reset; a missing MicMatrix handshake afterward is expected. The app disables that board's matrix output but leaves other lights and the Mac app running. Quitting/uninstalling the app alone never reflashes the board. Keep the backup folder if you want to restore later.

### Interruption protection and recovery

- Normal app Quit/Command-Q, relaunch and cancellation are blocked during erase/write/verification. Writing reaching 100% is not completion; wait for verification and reconnection.
- A macOS assertion prevents automatic idle-system sleep during protected work. Closing/hiding Settings does not own or terminate the operation.
- Cancellation is available before erasure and waits for safe helper cleanup. No ordinary “Quit anyway” is offered mid-flash.
- **Force Quit, crashes, forced sleep/lid closure, power loss and physically unplugging USB cannot be prevented.** Keep power and the USB cable stable. Interrupted flash may leave no bootable app, but retained backups and the ROM bootloader allow a retry.
- To enter download mode: hold **BOOT**, press and release **RESET**, then release **BOOT**. Re-select/re-inspect the same board if its serial path changes; retry installation or restore its verified original. Press RESET after a completed operation if necessary.
- Recovery journals remain on disk when an operation fails. Do not assume a board is ready merely because the helper exited or the original serial port disappeared.

### Download trust

The first installer build is Apple Silicon and locally/self-signed, not Apple-notarized. macOS can require explicit Privacy & Security approval for a downloaded quarantined copy, and managed Macs may refuse it. Obtain the app from this project's release assets and verify its checksum. Do not disable Gatekeeper globally or assume a downloaded source archive is a built app.

## Developer build and manual flash

For a complete distributable app, prepare the bundled runtime first:

```bash
bash tools/firmware/build.sh
bash build.sh
bash scripts/package-app.sh
```

The preparation script builds the clean image/manifest, tests/freezes a standalone arm64 helper using pinned esptool 5.3.1, and packages third-party licenses and corresponding sources. The helper is a separate process with its own contained Python runtime. Source archives `CorrespondingSource.tar.gz` and `NativeRuntimeSource.tar.gz` accompany it in app resources. See [the helper tooling](tools/firmware/) for its developer requirements. A missing helper/image stops the app build rather than producing a misleading installer.

Developer tests:

```bash
bash scripts/test-firmware.sh
build/firmware-python/bin/python -m unittest discover -s tools/firmware/tests -v
build/firmware-python/bin/python tools/firmware/tests/frozen_smoke.py build/FirmwareTools/MicMatrixFlasher
```

The optional diagnostic `--cli firmware` commands call the same app service as Settings, not an external esptool installation. Destructive diagnostics require explicit `--confirm-board --confirm-erase` and always take a verified backup. Close competing app/serial connections before using diagnostics.

### Installer verification

The connected Waveshare test board completed **custom → original stock → bundled MicMatrix → original stock → bundled MicMatrix**, finishing on healthy custom firmware. Every restore/install used the app's contained helper and verified the complete flash image before reset. The original factory backup was preserved unchanged, and each destructive operation retained a verified safety snapshot.

The actual app was launched with restored stock connected: its bounded handshake released the port without repeated reconnect ownership. Automatic detection correctly reported possibly-stock; explicit inspection matched the known stock executable fingerprint. A diagnostic invoked the same native termination delegate during real restore/install protected phases and verified that Quit was rejected, then allowed again after cleanup. This does not claim that Force Quit or physical unplugging can be prevented.

Automated coverage includes 59 helper tests, frozen-runtime fail-closed requests without board access, Swift termination/backup/image/process tests, 17 existing matrix tests and 7,344 Swift/firmware rendering comparisons. The embedded Python/native dependency closure was checked for unresolved developer/Homebrew paths. Hardware testing simulates out-of-box state using the same board's official original backup; it does not prove compatibility with every factory firmware revision or an Intel Mac.

Install app v3.0.0 or newer before flashing v4 firmware: earlier app releases do not recognize the new handshake. Saved settings and brightness defaults are preserved.

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

Fresh v4.0.0 settings (unchanged from v2.0.1):

| Status | Icon | Full color | Relative level | Effect |
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

- **Full color** (formerly Original palette): preserves artwork hue; saved color's strongest channel determines palette gain. Fresh defaults use full gain.
- **Tint artwork:** multiplies RGB channels by the tint; complementary colors may disappear.
- **Single color:** fills the artwork mask with the chosen color.
- **Enabled / 0%:** the Enabled switch or 0% brightness hides a status without changing the selected icon. Black/Off is also available in the color picker.
- **AFK:** A/F/K cycle every 0.8 seconds in cyan/yellow/green.
- **Shrug:** `¯\_(ツ)_/¯` scrolls right-to-left at eight pixels/second, preserving reading order.
- **Adobe A:** a hand-tuned red pixel approximation with shaded edges, not an official asset. Legacy identifier: `shield`.

Animated icons run even with Solid selected. Palette, gamma, brightness and orientation apply to every frame. Hero/chooser previews animate but deliberately do not scale with brightness sliders.

Color controls open a 4 x 4 swatch popover with a validated six-digit custom hex field. Swatches apply immediately; custom text commits only on Apply or Return. Matrix Test buttons are at each card's top right and preview that status on all enabled lights for three seconds. Hover over the master brightness information icon for relative-brightness guidance.

Configure call-start rainbow only in **Settings > Effects**. It is enabled for new installs, temporarily replaces artwork with a full-panel rippling rainbow wash, and restores the status after the configured duration. It uses master brightness. The manual Test rainbow can add a dark lead-in and remains available when automatic playback is off. Other USB outputs retain single-color sweeps.

### Lock and sleep

When detection is neither Live nor Muted, macOS screen lock, inactive session, display sleep or system sleep blanks the matrix. Returning to an unlocked, active, awake session restores it. No separate idle timer or Settings toggle is used.

Actual call states are exempt from lock/display-sleep blanking. During system sleep, USB updates stop and the watchdog clears stale output regardless. Previews and rainbow tests cannot override no-call automatic blanking. Other outputs keep their existing behavior.

## Orientation and connection

Gravity is filtered at 25 Hz; quadrant changes must remain stable for 200 ms. Hysteresis avoids diagonal flicker. Flat poses, free fall and large accelerations retain the last orientation. Stale or unavailable IMU data blanks the board and reports an error.

Mapping: positive/negative X selects turns 3/1; positive/negative Y selects 0/2. A fixed 180-degree mounting correction is applied before the user offset. Mirror calibration also adjusts rotation handedness.

The Orientation icon has an upward arrow and lower-left dot. Use it to check all four upright positions. The always-visible **Orientation** row has a 0/90/180/270-degree segmented offset picker and a **Mirror** switch. Mirroring flips artwork horizontally before orientation mapping.

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

CLI `off` remains supported for dark frames. In Full color mode, white means full palette intensity, not white artwork.

## USB protocol v4

115200 baud, ASCII newline-terminated commands:

| Command | Reply |
|---|---|
| `HELLO` | `MATRIX 4 8 8 25 PRESET1`, only with healthy IMU |
| `PRESET seq icon style RRGGBB brightness flags relative effect rate effectPhase iconPhase` | `OK seq` |
| `KEEP seq` | `OK seq`, only while the display lease is active |
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
- PRESET icon: the saved/CLI identifier (including legacy `off`). Style: 0 original artwork, 1 tinted, 2 solid color.
- Relative intensity: 0-10000 (0-100%, 0.01% resolution). Effect: 0 solid, 1 pulse, 2 flash. Rate: 100-10000 millihertz (0.1-10 Hz).
- Phase offsets: unsigned 32-bit milliseconds, separately for the effect and icon animation. KEEP does not restart either phase. Presets explicitly carry current phases when state/settings change or a connection is restored.

Parsing is atomic. Malformed input returns `ERR ...` without replacing the display or renewing its watchdog. Timeout blanks LEDs and emits `TIMEOUT`. HELLO, STATUS, ORIENTATION, orientation redraws and local animation do not renew the three-second timeout. KEEP renews only an unexpired lease; it cannot relight an expired/OFF display. A new valid PRESET/FRAME/DRAW is required. Boot, OFF and IMU failure clear the display and stop its animation.

PRESET applies the same palette/tint/solid selection, gamma-2.2 and relative gain on the board, then the existing master brightness cap. FRAME remains raw RGB: the app applies gamma/relative gain before transmission, and firmware does not apply gamma twice.

The app recognizes v4's exact `PRESET1` capability handshake and v3's `MATRIX 3 8 8 25`. V3 uses legacy FRAME streaming. Earlier protocols/ceilings are rejected. **Install the matching updated app before flashing v4**: older app builds recognize only v3 and cannot control v4 firmware. Keep the verified original/current flash backup for rollback.

### Control scheduling and safety design

- **Steady state:** send one preset on changes; acknowledge and coalesce the latest desired state, with at most one command in flight. Send a small KEEP approximately once per second. There is no host 25 Hz timer for matrix-only presets.
- **Transport:** serial read/write readiness events drain replies and resume partial writes. A 1 Hz maintenance timer handles heartbeat, handshake/ACK deadlines and reconnect. Discovery runs only when enabled and disconnected; connected ports report failures through I/O. Disabled, paused and automatically blanked outputs close the port and cancel maintenance.
- **Firmware:** immutable artwork is generated from the existing Swift source, not a table of every effect/rate combination. Pulse/flash use formulas; AFK cycles every 800 ms; Shrug scrolls every 125 ms. Animated presets evaluate at up to 100 Hz, improving fast-flash timing; identical pixel buffers are not redrawn. Solid graphics redraw only on changes/orientation.
- **Safety:** local rendering cannot renew the independent three-second host lease. Brightness, IMU stale-sample blanking, explicit OFF on release and bounded serial parsing remain enforced. The menu-bar pulse and Teams polling are deliberately unchanged.
- **Bounded exception:** call-start/manual full-panel rainbow effects still stream frames at up to 25 Hz for their short duration, then restore the status preset. Other enabled software-animated USB outputs can still require the host timer; invisible/disabled outputs do not.

After artwork changes, regenerate the firmware catalog before building/flashing:

```bash
bash scripts/generate-matrix-firmware-artwork.sh
```

The native test suite checks that the committed generated catalog matches the Swift source.

## Validation

### Animation performance benchmark

Build first, then quit the menu-bar app (or disable its matrix output) to release the port:

```bash
bash scripts/test-animation-performance.sh "D4:05:92:40:89:A0" 8
# Optional third argument: JSON output path; default build/animation-performance.json.
# Add a fourth argument --presets to require the v4 steady-state traffic/timer limits.
```

The CLI benchmark runs the real controller, effect renderer and serial driver with isolated in-memory settings, at 5% master brightness. It does not read/write saved settings or Keychain, run Teams detection, send to other lights, or lock the actual screen. Eight scenarios each have 1.5 seconds of warm-up before the timed sample. On v4, the Live case additionally plays a bounded rainbow before sampling and asserts that host animation stops after preset restoration. Menu-bar pulse timer activity is included for the Live scenario, but GUI image drawing and Settings rendering are not. The lock case injects the same availability state used by macOS notifications.

JSON records elapsed time, process CPU time (`clock()`, percent of one CPU core), actual controller animation callbacks/render calls, acknowledged USB commands (the historical `acknowledgedFrames` field includes KEEP), successfully written bytes, driver maintenance timer callbacks, and discovery calls. Read/write readiness events are not counted as timer callbacks. Timer callbacks are **not** kernel wakeup counts. CPU includes the benchmark's run-loop harness and is not a measurement of battery power, whole-app GUI cost, Teams CPU, or firmware CPU. Timing/CPU vary with system load; assertions check functional traffic/rate bounds rather than brittle CPU thresholds.

Initial physical-board baseline (2026-11-10, release build, eight seconds per scenario):

| Scenario | Controller ticks/s | USB frames/s | USB bytes/s | Process CPU, one core |
|---|---:|---:|---:|---:|
| All outputs disabled, Pulse selected | 25 | 0 | 0 | 0.70% |
| Matrix Solid | 0 | 1 | 398 | 0.66% |
| Matrix Pulse, 1 Hz (Live) | 25 | 21 | 8,392 | 1.59% |
| Matrix Flash, 1 Hz | 25 | 2 | 800 | 0.97% |
| Matrix Flash, 10 Hz | 25 | 20 | 8,050 | 1.58% |
| AFK, Solid | 25 | 1.25 | 500 | 0.90% |
| Shrug, Solid | 25 | 7.87 | 3,149 | 1.14% |
| Matrix blanked by simulated lock, Pulse selected | 25 | 0 | 0 | 0.72% |

The original driver ran about 25 callbacks/s and one discovery/s in all cases. These short baseline samples confirmed unnecessary controller work without animated visible output, while frame coalescing already prevented a constant 25-fps USB stream.

### Optimized physical-board results

V4, same board/release build/5% brightness/eight-second samples (2026-11-10):

| Scenario | Controller ticks/s | USB commands/s | USB bytes/s | Process CPU, one core |
|---|---:|---:|---:|---:|
| All outputs disabled, Pulse selected | 0 | 0 | 0 | 0.41% |
| Matrix Solid | 0 | 1 | 7 | 0.43% |
| Matrix Pulse, 1 Hz (Live) | 0 | 1 | 8 | 0.45% |
| Matrix Flash, 1 Hz | 0 | 1 | 8 | 0.41% |
| Matrix Flash, 10 Hz | 0 | 1 | 8 | 0.39% |
| AFK, Solid | 0 | 1 | 8 | 0.40% |
| Shrug, Solid | 0 | 1 | 8 | 0.42% |
| Matrix blanked by simulated lock, Pulse selected | 0 | 0 | 0 | 0.40% |

Enabled steady states used one maintenance callback/s and zero discovery calls. Disabled/blanked states used neither. Pulse traffic fell from about 8,392 to 8 bytes/s (over 99.9%); short-sample CPU fell from 1.59% to 0.45% of one core. This is not a battery-life claim. A separate physical test sampled STATUS during autonomous 10 Hz flashing and measured a 50.0 ms mean on/off edge interval (100 ms full cycle); it sends no frame updates. Firmware scheduling remains best-effort, not hard real-time. V3 compatibility was also measured before flashing: animated streaming remained functional, while idle/blanked controller timers and connected discovery were eliminated.

### Functional and hardware tests

```bash
bash scripts/test-matrix.sh
bash scripts/generate-matrix-gallery.sh
bash build.sh
arduino-cli compile --profile matrix --output-dir build/firmware firmware/MicMatrix
# Optional physical tests; close the app's matrix output first:
python3 scripts/test-matrix-hardware.py /dev/cu.usbmodem11401 --app "$APP"
python3 scripts/test-matrix-hardware.py /dev/cu.usbmodem11401 --orientation-test
```

The Swift/C++ tests need no XCTest or full Xcode. Seventeen Swift tests, firmware parser/renderer/lease tests (including rollover), and 7,344 byte-exact cross-language render fixtures cover every selectable graphic, all styles/effects, multiple rates/phases/colors and relative gain. Hardware tests check handshake, IMU, busy-port errors, brightness floor/ceiling/zero, relative dimming, gamma-corrected red, watchdog, oversized/malformed input, 25 fps legacy transport and all 64 independent RGB pixels. V4 additionally tests local pulse/flash, KEEP phase preservation, atomic preset rejection and lease expiry despite ongoing animation/invalid traffic.

Artwork is defined in [MatrixProtocol.swift](Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift); the SVG generator uses the same source pixels. Physical orientation, lock/unlock restoration, call-start restoration, and menu-bar pulsing were also tested interactively.
