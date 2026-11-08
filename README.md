# Teams Mute Light v2.0

A small macOS menu bar app that shows whether **Microsoft Teams** has you **muted or unmuted**, not just whether the mic is active, on USB lights, an 8x8 RGB matrix, or a Home Assistant light.

**Release 2.0.0** adds native Waveshare matrix support, full-color artwork and animations, relative status brightness, automatic lock/sleep blanking, and a colored menu-bar indicator. See [release notes](CHANGELOG.md).

- **Detection:** the Teams local API (official, event-driven) with an automatic fallback to reading the Teams mic button through the macOS Accessibility API.
- **Outputs:** Kuando Busylight, BlinkStick (Nano/Strip/…), Waveshare ESP32-S3 Matrix over USB, Home Assistant light entity, generic webhook, or WLED. You can turn on any combination.
- **Modes:**
  - **Companion:** your Kuando Busylight keeps running on its own software for meeting/presence, and a second light (Matrix, BlinkStick, HA, WLED) shows mute state.
  - **Kuando-only:** this app drives the Busylight itself: green = available, amber = in a meeting and muted, red = live.
- Per-light colors and brightness, visual matrix icon/palette selection, a device picker, launch at login, and pause/test from the menu.

## Requirements

- macOS 14 or later
- Xcode or the Command Line Tools (`xcode-select --install`), which gives you `swift`
- New Microsoft Teams (`com.microsoft.teams2`). Classic Teams is detected for the Accessibility fallback only.

## Build and run

```bash
cd mic-mute-indicator
chmod +x build.sh scripts/*.sh
./scripts/create-signing-cert.sh   # once: stable signature so Accessibility grants stick
./build.sh                        # builds and signs build/Teams Mute Light.app
# Quit the running app before replacing it.
osascript -e 'tell application "Teams Mute Light" to quit'
ditto "build/Teams Mute Light.app" "/Applications/Teams Mute Light.app"
codesign --verify --strict "/Applications/Teams Mute Light.app"
open "/Applications/Teams Mute Light.app"
```

A status beacon shows up in the menu bar. Open **Settings…** from it.

The icon is a status beacon, deliberately not a mic, so it doesn't get confused with macOS's own mic indicator.

| Icon | Color | Meaning |
|---|---|---|
| `light.beacon.min` (outline) | White | Not in a call / Teams not running |
| `light.beacon.min.fill` | Green | In a call, muted |
| `light.beacon.max.fill` (with rays) | Pulsing red | **Live — mic is on** |
| `lightbulb.slash` | White | Can't read Teams (e.g. Accessibility not granted) |
| `pause.circle` | White | Lights paused |

Colors follow detected call state, not temporary previews. The red pulse has a 1.5-second period and uses a bounded timer; it is independent of light-output brightness and effects.

Settings has four tabs:
- **General:** status, anything that needs fixing, launch at login.
- **Lights:** each output's device, colors and brightness; Matrix has three visual cards (Live, Muted, Not in meeting), a shared master slider, and collapsed orientation calibration.
- **Effects:** pulse/flash per state and the call-start rainbow.
- **Advanced:** detection method, mute-button matching, diagnostics and the log.

## Proof of concept with the Kuando Busylight (do this first)

1. **Quit the kuando HUB / Busylight app**, or it will fight this app for the light.
2. Test the USB path:
   ```bash
   APP="/Applications/Teams Mute Light.app/Contents/MacOS/TeamsMuteLight"
   "$APP" --cli devices            # should list your Busylight (VID 27BB)
   "$APP" --cli cycle kuando       # red → green → blue → amber → off
   "$APP" --cli kuando "#FF0000" 5 # solid red for 5 s
   ```
3. Test detection (give your terminal app Accessibility permission for the AX part):
   ```bash
   "$APP" --cli watch              # join a Teams meeting, press ⌘⇧M a few times
   "$APP" --cli ax-dump            # lists every Teams button label, handy if matching fails
   ```
4. Launch the app. In **Settings › Lights**, keep "Drive the Kuando Busylight" on and pick **Kuando-only preset** or **Mute-light preset**.

## Teams detection setup

### 1. Teams local API (preferred)

1. In Teams go to **Settings › Privacy › Third-party app API › Manage API** and turn on **Enable API**.
2. Join any meeting (a "Meet now" with just yourself is fine).
3. From the menu bar icon choose **Pair with Teams (toggles mute once)**. Teams shows a prompt to allow the new device. Click **Allow**.
4. The token is saved to your Keychain. From then on Teams pushes `isMuted` / `isInMeeting` the moment they change, with no polling and no permissions needed.

If **Third-party app API** isn't on your Privacy page, your Teams build or your org doesn't expose it. That's common on current new-Teams builds and managed tenants. Some people get it back by signing out of Teams and back in; otherwise ask IT. To confirm, `lsof -nP -iTCP:8124 -sTCP:LISTEN` prints nothing when the API is off. In that case set **Settings › Advanced** to **Accessibility only**. Auto mode works either way; it just keeps retrying the API quietly in the background.

### 2. Accessibility fallback

Grant **System Settings › Privacy & Security › Accessibility** to *Teams Mute Light* (the app prompts you). The app finds the meeting mic button, preferring DOM id `microphone-button`, and reads its label:

- "Unmute mic" / "Unmute (⌘+Shift+M)" means you are **muted**.
- "Mute mic" / "Mute (⌘+Shift+M)" means you are **unmuted**.

Both regexes can be edited in **Settings › Advanced**. If Teams changes its labels or runs in another language, run **Dump Teams Accessibility Tree…** during a meeting and adjust them. Full-tree scans are throttled while you're not in a meeting (about every 2 s if any mic is in use, 10 s otherwise). Once the button is found, only that element is re-read, every 0.5 s.

> **Do this once:** `./scripts/create-signing-cert.sh`. macOS ties the Accessibility grant to the app's code signature. Ad-hoc signatures change on every build, so the toggle in System Settings can be on while the app still sees "Not granted". The script creates a local self-signed "TeamsMuteLight Local" identity, which `build.sh` then uses automatically, so grants survive rebuilds.
>
> **Fixing a stale grant:** in System Settings › Privacy & Security › Accessibility, remove *every* Teams Mute Light / TeamsMuteLight entry with **–**. Don't add the inner `Contents/MacOS/TeamsMuteLight` binary: the entry must be the `.app`. Then click **Grant…** in the app, switch the new entry on, and click **Relaunch**. As a last resort, `tccutil reset Accessibility com.eroper.TeamsMuteLight` wipes the entry.

## Hardware and outputs

| Output | How it talks | Notes |
|---|---|---|
| **Kuando Busylight** (Alpha/Omega/UC/…) | USB HID, 64-byte output report, keep-alive every 5 s | VID `27BB` (+ legacy `04D8:F848`). Quit kuando's software first. |
| **BlinkStick** (Nano, Strip, Square) | USB HID feature reports 1 & 5 | VID:PID `20A0:41E5`. Nano = 2 LEDs (set "LEDs to light"). |
| **Waveshare ESP32-S3 Matrix** | Native USB serial, MicMatrix firmware | Auto-upright 8x8 RGB icons; no Wi-Fi required. Default brightness 2%, slider limit 10%. |
| **Home Assistant** | `POST /api/services/light/turn_on` / `turn_off` | Long-lived token in Keychain. Any RGB light entity (Hue, Zigbee bulb, ESPHome LED…). |
| **Webhook – Generic** | `POST {"state","color","r","g","b","brightness"}` | Node-RED, HA webhook automations, your own ESP32 sketch. |
| **Webhook – WLED** | `POST http://<ip>/json/state` | Cheapest DIY: ESP32/ESP8266 + a WS2812 LED + WLED firmware. |

DIY options if you'd rather not buy a BlinkStick:
- **ESP32 + WLED + one WS2812B LED:** no code to write. Flash WLED from the web installer and point the webhook at `http://<ip>/json/state` in WLED format.
- **BlinkStick-compatible DIY:** BlinkStick firmware is open source (ATtiny85/V-USB). A Digispark clone with BlinkStick firmware shows up as `20A0:41E5` and works with the BlinkStick output.
- **Home Assistant:** any smart RGB bulb or ESPHome light already in HA works with the HA output.

### Waveshare ESP32-S3 Matrix over USB

The [ESP32-S3-Matrix](https://docs.waveshare.com/ESP32-S3-Matrix) uses 64 addressable LEDs on GPIO 14. Our small [Arduino firmware](firmware/MicMatrix/MicMatrix.ino) renders full-color 8x8 RGB frames and legacy monochrome bitmaps, using the top-right/progressive-column layout from Waveshare's font example. Physical tests confirmed **RGB** byte order, matching the game example rather than the font example's GRB setting. Its QMI8658 accelerometer on SDA 11 / SCL 12 keeps graphics upright in 90-degree steps. Wi-Fi, Bluetooth, and the gyroscope are unused.

**Heat precaution:** Waveshare warns that excessive LED brightness can damage this board. After initial 20% and 10% tests proved too bright, the default is 2% (`5/255` pixel output). The matrix slider ranges from 1% to 10%; app and firmware cap actual pixel output at `25/255` (9.8%, rounded down to stay below 10%). Absolute output/master brightness sliders have a 1% floor (matrix relative status sliders run from 0% to 100%), and saved nonzero levels below it are normalized on load. Explicit zero, dark colors, Display toggles, and Off commands remain off. Matrix firmware floors nonzero brightness at `3/255` to avoid sub-1% settings that light no pixels. Raising the ceiling does not raise an existing user's saved brightness. Firmware scales every RGB channel explicitly, including arbitrary bitmaps and animation frames. Prefer sparse icons rather than sustained full-panel white. This limit is a development precaution, not a thermal guarantee; unplug the board if it gets unusually hot.

#### Build and flash

Install `arduino-cli` (`brew install arduino-cli` on macOS), then build using the pinned core/library and native hardware USB CDC settings:

```bash
arduino-cli compile --profile matrix --output-dir build/firmware firmware/MicMatrix
arduino-cli board list
```

The pinned profile uses ESP32 Arduino core 3.3.12, Adafruit NeoPixel 1.15.5, and SensorLib 0.5.1. The first profile build downloads the required dependencies. Flashing **replaces the board's current program**. Disable this app's matrix output and close serial monitors before accessing the port. Back up the original flash first; it may contain Wi-Fi credentials, so keep backups outside Git:

```bash
ESPTOOL="$HOME/Library/Arduino15/packages/esp32/tools/esptool_py/5.3.1/esptool"
PORT="/dev/cu.usbmodem11401"  # use the actual current port; it can change
BACKUP="$HOME/Library/Application Support/TeamsMuteLight/FirmwareBackups"
mkdir -p "$BACKUP"
chmod 700 "$BACKUP"
# Choose a fresh filename; do not overwrite your original backup.
"$ESPTOOL" --chip esp32s3 --port "$PORT" read-flash 0 ALL "$BACKUP/original.bin"
chmod 600 "$BACKUP/original.bin"
shasum -a 256 "$BACKUP/original.bin"
# Verify the saved image matches the board before replacing its program.
"$ESPTOOL" --chip esp32s3 --port "$PORT" verify-flash 0 "$BACKUP/original.bin"
# Only proceed after a successful backup (4 MiB for this board).
arduino-cli upload --profile matrix --port "$PORT" --input-dir build/firmware firmware/MicMatrix
```

If it cannot enter download mode, hold BOOT, press/release RESET, then release BOOT and select the new port. Press RESET if the firmware does not start after upload. Restore an original backup with `"$ESPTOOL" --chip esp32s3 --port "$PORT" write-flash 0 "$BACKUP/original.bin"`.

#### Use in the app

Rebuild/install the Mac app, then enable **Settings > Lights > Waveshare ESP32-S3 Matrix (USB)**. Select the board by USB serial number if other Espressif devices are attached. Discovery identifies Espressif serial ports, then a firmware handshake verifies MicMatrix v3 and a working accelerometer before sending any display commands. A specifically selected serial never falls back to another board.

Choose a per-state icon, artwork mode, and brightness. Full-color artwork is enabled by default: a red live microphone with cream highlights, a green muted microphone with cream highlights and a red slash, layered red/orange/yellow flames, and other multicolor designs. Heart, Adobe A, rainbow, headphones, and moon are also available. Adobe A replaces Shield with a red-only pixel rendition of the central logo and unlit negative space; the saved/CLI identifier remains `shield` for compatibility. Every pixel has independent 24-bit RGB values.

Each status has its own color mode: **Original palette** uses the artwork's colors, **Tint artwork** multiplies each pixel's RGB channels by the chosen tint, and **Single color** uses the chosen color on the icon's mask. Tint retains shading but can suppress complementary colors. The dot's built-in palette uses dark red, crimson, and coral shades. In Original palette mode the saved state color controls intensity via its brightest channel; black hides the icon. Existing pulse/flash effects dim the whole palette together. Brightness defaults to 2%, with the same 10% slider ceiling and firmware safety limit.

Each of the three editable matrix statuses also has a **0–100% brightness** slider relative to **Master matrix brightness**. For example, Live at 100% and Muted at 50% with a 2% master produce approximately 2% and 1% output. All statuses default to 100% to preserve existing brightness settings. Relative dimming scales the gamma-corrected RGB output, allowing output below the master's 1% floor; 0% hides that status without changing its icon or color. The LEDs have limited precision, so very low levels can disappear and percentages are approximate. Test buttons and status effects honor these levels; other lights are unchanged, and the full-panel call-start rainbow uses only the master. CLI hardware demos use their fixed 2% brightness with no per-status dimming.

**Matrix color correction:** Before serial transmission, the app converts artwork, picked colors, and rainbow frames to linear LED intensities using a gamma-2.2 lookup table. Relative status brightness is applied **after** this conversion, then firmware applies the master PWM and its safety ceiling. This suppresses weak green/blue channels that previously became visible as brightness increased, reducing washed-out reds without removing intentional pink/cream heart highlights. Pure red, green, blue, white, and black remain unchanged. The gallery and chooser show the original display-encoded artwork; gamma correction is for the physical LEDs, not the on-screen preview. Low PWM precision can still cause subtle color steps; gamma correction is not measured hardware calibration.

**Matrix call-start animation:** The rainbow sweep temporarily replaces the icon with a dedicated 64-pixel rainbow wash: moving diagonal hue bands and a rippling flow across the whole 8x8 panel. It ignores icon masks, state colors, and palette mode, but respects matrix brightness, orientation, and the firmware limit. Both automatic call start and the manual Rainbow Sweep preview use it. After the configured duration, the current status icon and its normal effect return automatically. A preview's optional blackout lead-in stays dark. Other USB lights retain their existing single-color rainbow sweep.

Settings presents **Live, Muted, and Not in meeting** in three adjacent cards. Unavailable has no editable card: it automatically displays the red warning exclamation point with yellow accents at master brightness, regardless of old saved Unavailable icon/color/level choices. Click a pixel preview to open the visual icon gallery; gallery thumbnails are half the width and height of the selected hero preview. Each card contains one icon chooser, a Display toggle, palette mode, tint/color control where relevant, and Test button. A single shared brightness slider sits below the cards; orientation offset and mirror controls are tucked into a calibration disclosure. Tests preview all enabled lights. The matrix starts disabled on a fresh installation; existing enables, colors, and brightness are preserved when upgrading, including legacy single-color mode. When ready, enable the matrix and disable the Kuando toggle to return the Busylight to its own software.

#### Artwork gallery

**Unavailable** means mic detection is unknown, not Teams presence (Busy/Away/Do not disturb). It can occur without Accessibility permission, when API-only mode is unpaired/disconnected, or when the paired API reports a meeting but no mute state. Auto mode falls back to Accessibility and can therefore avoid this state. Teams not running or no meeting mic button found normally means Not in meeting. Warning remains selectable for any of the three editable statuses. Use that status card's Test button to preview it without causing a detector failure.

Settings hero previews show artwork at full illustrative intensity, independent of master/status brightness and saved color intensity. Tint and single-color previews retain the chosen hue with normalized intensity; Display-off colors remain dark. This changes only the preview, not the LEDs. Adobe A uses a narrower shaded crown with low-intensity red edge pixels to soften the upper silhouette.

Adobe A follows the supplied modern connected silhouette, with symmetric upper shoulders/legs, a dark triangular counter, and the distinctive lower diagonal opening. Red edge shading helps its 8x8 outline without adding other colors. The [classic Adobe SVG](https://cdn.jsdelivr.net/npm/simple-icons@13/icons/adobe.svg) was consulted as a comparison reference; it is a different, disconnected mark, not the shape used here. This is a hand-tuned pixel approximation, not an official logo asset.

**Automatic overnight blanking:** When the detected status is neither Live nor Muted, the matrix turns off when macOS locks the screen (manually or automatically), switches away from your user session, sleeps the display, or sleeps the Mac. It restores the current status when the session is unlocked/active and awake. Live/Muted call states are exempt; actual system sleep still stops USB updates and the firmware watchdog clears stale output. This is matrix-only, uses macOS events rather than a separate inactivity timer, and has no Settings toggle. Preview icons and rainbow tests cannot override blanking while there is no detected active call. Other light outputs keep their existing behavior.

The visual chooser has **16 choices including Warning**, which replaces Off. Display toggles still turn statuses off; old saved Off icons and the CLI `off` identifier remain supported for compatibility. Muted microphone uses green mic shading with its red diagonal slash; No sign is a red-only circle and slash with coral rim highlights. New choices:

- **AFK:** large A, F, K letters cycle every 0.8 seconds in cyan, yellow, and green.
- **Smiley:** a classic yellow face with dark eyes and a curved smile.
- **Shrug:** pixel glyphs for `¯\_(ツ)_/¯` scroll **right to left** at eight pixels per second and loop with a blank gap. The text retains its reading order and is not mirrored.

Animated choices run even with the status effect set to Solid. Palette/tint/single-color mode, relative status brightness, gamma correction, automatic orientation, and pause/timeout behavior all still apply. Chooser thumbnails and selected previews animate, as do AFK and Shrug in the SVG gallery when opened directly (some README renderers may show only a still frame). The 16 designs fill four gallery rows with three variants each.

![Full-color matrix artwork and single-color variants, on simulated dark circuit boards](Resources/matrix-gallery.svg)

[Open the full-size gallery](Resources/matrix-gallery.svg). Each miniature has exactly 64 simulated LED packages, with soft glow and a dark circuit-board background. The preview is generated from the same pixel arrays used by the app, not an AI approximation. Glow/exposure is illustrative, not a prediction of physical brightness. The compact four-column gallery shows each full-color design above smaller red and cyan single-color alternatives.

Regenerate after editing the palette or icons:

```bash
bash scripts/generate-matrix-gallery.sh
```

Artwork lives in `MatrixIcon.artwork` in [MatrixProtocol.swift](Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift): eight rows of eight palette symbols per design. The USB protocol can also accept arbitrary frames, not only these built-in icons.

**Auto-orientation:** Firmware samples acceleration at 25 Hz, filters gravity, and requires a new quadrant to remain stable for 200 ms. Hysteresis avoids flickering at diagonal angles. Face-up/face-down flat poses, free fall, and large accelerations retain the last stable orientation: gravity cannot define screen-up when the screen is horizontal. Orientation changes redraw the cached icon without waiting for a Mac update and do not renew the 3-second display timeout. An unavailable/stale accelerometer blanks the display and reports an error instead of silently pretending orientation works.

The sensor-to-display mapping compensates for opposite X-axis handedness: positive/negative X select clockwise turns 3/1, while positive/negative Y select 0/2. Rendering also applies a fixed 180-degree mounting correction before the user offset, consistently across all four positions.

Use **Orientation offset** and **Mirror calibration** to correct the matrix's fixed mounting/wiring relationship to the sensor. Mirror calibration also reverses rotation handedness so automatic orientation still works after a reflection. The orientation-test icon is an up arrow with a single dot at the lower-left corner; check it while turning the board through four upright positions.

The firmware starts dark, clears after **3 seconds without a valid FRAME or DRAW**, and accepts an explicit OFF on pause/disable/quit. The app resends the current frame at least once per second even for solid states, checks acknowledgements, and reconnects after unplug/replug. Serial I/O is nonblocking and runs off the UI thread.

With the matrix output disabled in the running app:

```bash
APP="/Applications/Teams Mute Light.app/Contents/MacOS/TeamsMuteLight"
"$APP" --cli matrix-probe                # handshake + acknowledged dark frame
"$APP" --cli matrix-test                 # five short icons below 2%, then off
"$APP" --cli matrix-rainbow              # bespoke full-panel flow for 3 s at 2%, then off
"$APP" --cli matrix fire "#FF8200" 3      # one icon below 2%, then off
"$APP" --cli matrix heart "#FFFFFF" 3    # pink/red artwork; white means full palette intensity
"$APP" --cli matrix afk "#FFFFFF" 5      # A, F, K letter cycle
"$APP" --cli matrix shrug "#FFFFFF" 6    # right-to-left scrolling shrug
"$APP" --cli matrix warning "#FFFFFF" 3 # red ! with yellow accents
"$APP" --cli matrix shield "#FFFFFF" 3  # Adobe A; legacy CLI identifier
"$APP" --cli matrix orientation "#FF0000" 20
# Optional explicit calibration after the serial argument: offset 0...3, mirror 0 or 1
"$APP" --cli matrix orientation "#FF0000" 20 "D4:05:92:40:89:A0" 0 0
```

#### USB protocol v3

115200 baud, ASCII newline-terminated commands, no serial debug monitor needed:

- `HELLO` -> `MATRIX 3 8 8 25` (only with healthy accelerometer samples)
- `FRAME <uint32-sequence> <brightness> <orientation-flags> <384-hex-RGB-pixels>` -> `OK <sequence>`
- `DRAW <uint32-sequence> <r> <g> <b> <brightness> <orientation-flags> <16-hex-bitmap>` -> `OK <sequence>`
- `OFF <uint32-sequence>` -> `OK <sequence>`
- `STATUS` -> `STATE <lit-pixel-count> <max-red> <max-green> <max-blue>` (actual output buffer after brightness scaling)
- `ORIENTATION` -> `ORIENT <gravity-quarter-turn> <x-mg> <y-mg> <z-mg> <upright-0-or-1>`

FRAME carries exactly 64 consecutive `RRGGBB` hex colors, row-major from the top-left, totaling 384 hex characters. All 64 pixels may have different colors. Lines are bounded at 448 bytes; the USB receive queue is 1024 bytes to accommodate complete frames. Parsing is atomic: malformed frames never partially replace the current display. DRAW remains supported for single-color clients and follows the same rendering/safety path.

RGB and brightness input are 0...255; firmware clamps brightness to 25 per channel after scaling. Orientation flags are 0...7: bits 0...1 are the fixed clockwise offset, bit 2 enables mirror calibration; gravity orientation and the mounting correction apply to every pixel, preserving the full-color cached frame. The legacy bitmap's most significant byte is the top row, with its most significant bit at the left. Invalid commands return `ERR ...` and do not renew the display timeout. Timeout clears the LEDs and emits `TIMEOUT`. HELLO, STATUS, ORIENTATION, and orientation redraws never renew the timeout. Earlier firmware must be upgraded to match this app's v3 handshake.

Validation:

```bash
bash scripts/test-matrix.sh
# Optional physical-board tests; disable its app output and use the current port:
python3 scripts/test-matrix-hardware.py /dev/cu.usbmodem11401
# Add --app "$APP" to also verify the Mac driver's busy-port handling.
# To observe live gravity telemetry and an automatically rotating arrow:
python3 scripts/test-matrix-hardware.py /dev/cu.usbmodem11401 --orientation-test
```

The standalone Swift/C++ runner works with Command Line Tools alone; XCTest/full Xcode is not required. The 15 Swift tests cover artwork, gamma correction, relative brightness, legacy settings, animations, lock/sleep policy, and menu-bar pulse colors. C++ tests cover atomic parsing, exhaustive brightness bounds, gravity orientation, and reflection. Physical USB checks cover handshake, busy-port handling, watchdog clearing, invalid-frame rejection, all 64 RGB pixels, relative dimming, and gamma-corrected red at multiple brightness levels.

## Project layout

```
Package.swift                 SwiftPM, macOS 14+, single executable target
build.sh                      assembles + signs the .app (and --install / --run)
Resources/Info.plist          LSUIElement (menu bar only), ATS local networking
Sources/TeamsMuteLight/
  Entry.swift                 @main, menu bar + Settings scenes, --cli switch
  AppController.swift         state resolution, output fan-out, launch at login
  Models.swift                RGB, MicState, per-light colors, settings (UserDefaults)
  Support.swift               logging, Keychain
  CLI.swift                   devices, matrix demos/probe, HID tests, ax-dump / watch
  Detection/TeamsAPIMonitor.swift      ws://127.0.0.1:8124 client (protocol 2.0.0)
  Detection/AccessibilityMonitor.swift AX mic-button reader + CoreAudio hint
  Outputs/HIDDeviceManager.swift       IOHIDManager hot-plug for USB lights
  Outputs/KuandoLight.swift            Busylight protocol + keep-alive
  Outputs/BlinkStickLight.swift
  Outputs/NetworkLights.swift          Home Assistant + Webhook/WLED
  Outputs/MatrixLight.swift            USB serial discovery, handshake, acknowledgements, reconnect
  Outputs/MatrixProtocol.swift         artwork/animations, gamma, settings, bounded commands
  UI/MatrixStatusEditor.swift          three status cards and animated visual chooser
  UI/MatrixPixelPreview.swift          code-native 8x8 preview
  UI/MenuContent.swift, UI/SettingsView.swift
```

`firmware/MicMatrix/` contains the reproducible ESP32 sketch; `Tests/` and `firmware/tests/` cover the protocol, brightness limits, icons, and settings migration.

`Resources/matrix-gallery.svg` contains 48 previews (16 choices in three color variants). `scripts/MatrixGallery.swift` generates it from the app's artwork, including animated AFK/Shrug frames. Build products and firmware backups are not source-release files.

## Upgrading to v2.0

- Install the new app using the same signing identity to retain Accessibility grants. App settings and existing output enables are preserved; the matrix remains disabled until explicitly enabled.
- Flash the matching MicMatrix firmware if upgrading from an older matrix build. The app requires the exact `MATRIX 3 8 8 25` handshake; an older ceiling or protocol is not accepted.
- Matrix master brightness remains at its saved level (default 2%); the new maximum does not automatically increase output. All three relative sliders default to 100%.
- Unavailable is now a fixed warning at master brightness, not an editable fourth card. It overrides old Unavailable artwork/color/relative-level settings, except that lock/sleep blanking still applies.
- Shield selections now display Adobe A. Legacy `shield` and `off` identifiers remain readable; Off is no longer offered in the chooser. Use Display toggles or a 0% status slider to turn a status off.
- The Git release tag is `v2.0.0`; the app version is `2.0.0`. Teams' API protocol remains `2.0.0` and the matrix wire protocol remains v3; these are separate from the app release version.

Hacking: `swift build && .build/debug/TeamsMuteLight` runs it unbundled for quick iteration. Launch at login needs the bundled `.app`, though.

## Troubleshooting

- **Busylight flickers or changes on its own:** the kuando software is still running. Quit it, or turn this app's Kuando output off.
- **Busylight goes dark after ~30 s:** the keep-alive isn't reaching it. Check **Settings › Advanced** for log/write errors.
- **"Teams API: Not connected":** the API isn't enabled in Teams, Teams isn't running, or your org blocks it. Auto mode falls back to Accessibility.
- **Matrix never lights or reports incompatible firmware:** select the correct USB serial, flash this release's pinned firmware, and check for `MATRIX 3 8 8 25`. Close serial monitors and other app instances; the port is exclusive.
- **Matrix goes dark on lock/display sleep:** expected when no Live/Muted call is detected. Unlock and wake the display to restore it. Actual system sleep also stops updates, triggering the three-second firmware watchdog.
- **Matrix colors change at very low brightness:** gamma correction reduces washout, but 8-bit PWM still quantizes weak channels. Increase relative/master brightness slightly or choose Single color for a pure-channel icon; remain within the thermal limit.
- **Unavailable warning appears:** detection is unknown, not Teams Busy/Away presence. Check Accessibility permission or API pairing in Advanced.
- **Menu-bar pulse freezes:** v2.0 uses a bounded timer rather than the timeline implementation that hung on unmute during development. If an older instance is still running, quit it and launch the installed v2.0 app. Firmware blanks stale LEDs automatically during an app hang.
- **Pair menu item missing:** you only see it while you're *in a meeting* and the API reports `canPair`.
- **Always "No meeting mic button found":** run the AX dump during a meeting and update the regexes, or send me the dump.
- **Home Assistant over plain `http://` to a non-`.local` hostname is blocked:** use HTTPS, an IP address, or `homeassistant.local` (ATS only allows local-network HTTP).

## References

- Teams local API protocol notes: [svrooij/teams-monitor](https://github.com/svrooij/teams-monitor)
- Kuando HID protocol reference: [yaddran/busylight](https://github.com/yaddran/busylight)
- Inspiration: [leonardodino/BeezyLight](https://github.com/leonardodino/BeezyLight)
