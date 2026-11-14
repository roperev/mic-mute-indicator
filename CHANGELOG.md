# Release notes

## v4.0.0 — 2026-11-13

- Added app-contained Apple Silicon firmware installation and original-firmware restore for the Waveshare ESP32-S3-Matrix, including a bundled clean firmware image and standalone flashing helper.
- General now shows evidence-based device/firmware status, identity inspection, default verified full backups, backup paths/Finder reveal/import and restore actions. A backup opt-out requires a separate destructive confirmation.
- Flash operations validate chip identity, flash size, security state and image checksums. The preserved first original is not replaced by later snapshots.
- Normal app termination, relaunch and cancellation are blocked during destructive writing/verification; idle sleep is inhibited and failures retain recovery journals. Force Quit, USB disconnection and power loss remain unavoidable interruption risks.
- Download packaging is locally/self-signed and not Apple-notarized. End users need no Python, Arduino CLI, Homebrew or runtime downloads; macOS approval may be necessary.
- Verified the real board from custom to its original stock, to bundled custom, back to stock and finally to custom, with complete flash verification and retained originals. Native Quit was rejected during actual protected flashing. Added 59 helper tests and contained-runtime/failure checks.
- Redesigned the four SwiftUI Settings tabs while retaining the fixed 760 x 1030-point window and original native styling.
- General now separates detected status from a labeled Pause lights switch, and adds project details, version/build and a GitHub link.
- Lights lists Waveshare Matrix first, followed by Kuando, BlinkStick, Home Assistant and Webhook/WLED. Streamlined matrix cards align controls, put Test at the top right and use compact Enabled switches and brightness percentages.
- Renamed Original palette to Full color without changing its rendering or saved identifier.
- Replaced native color panels throughout Settings with a shared 16-color swatch popover and validated custom hex entry. Invalid/unapplied text never changes the chosen color.
- Moved master brightness guidance into an information tooltip, removed gamma implementation notes from the controls, and replaced collapsed orientation calibration with an always-visible segmented offset picker and horizontal Mirror switch.
- Rebuilt Effects around per-state Solid/Pulse/Flash controls and a single call-start rainbow section. Fresh installs still enable the rainbow; saved choices are preserved.
- Clarified Teams button-label matching, replaced the polling slider with common interval choices, and tidied diagnostics and event-log actions.
- Added isolated desktop layout/hex-validation/settings-preservation checks plus firmware lifecycle/image/process safety tests. App version is 4.0.0 (build 6); the matrix rendering protocol, detection engine, output defaults and menu-bar behavior are unchanged.

## v3.0.1 — 2026-11-11

- Bumped the app version to 3.0.1 (build 5), visible in Settings > General, to distinguish the updated installed app.
- Retained the original SwiftUI-managed Settings appearance and increased its fixed content height from 680 to 1030 points, keeping the 760-point width. The window is intentionally not resizable.
- Removed the experimental native-window resize implementation. An automated Settings-scene test checks the actual 760 x 1030-point content size.
- No firmware, saved-settings, detection, or light-output behavior changes.

## v3.0.0 — 2026-11-10

### Device-control optimization

- MicMatrix v4 renders all selectable graphics, pulse/flash and AFK/Shrug animations locally using generated canonical artwork and parameterized effects.
- The app negotiates preset support, sends configuration only on changes, and maintains a small 1 Hz lease heartbeat. V3 firmware retains streamed-frame compatibility; temporary rainbow effects remain streamed.
- Serial replies/writes use readiness events rather than 25 Hz polling. Discovery runs only while enabled and disconnected; disabled/automatically blanked output has no matrix maintenance timer.
- Host animation stops when there is no visible output requiring software animation, including matrix-only presets. Teams detection and menu-bar pulse scheduling are unchanged.
- Independent three-second stale-host blanking, IMU safety, orientation, gamma, brightness limits and saved settings are preserved.
- Added reproducible hardware benchmarks, firmware preset/lease tests and 7,344 byte-exact Swift/firmware rendering comparisons. Install the matching updated app before using v4 firmware; older apps do not understand its handshake.

### Measured results

- Matrix-only presets eliminate the 25 Hz host animation timer; serial maintenance drops from 25 Hz to 1 Hz, with no connected-device discovery scans.
- Steady-state 1 Hz pulse USB traffic falls from approximately 8,392 bytes/s to 8 bytes/s (over 99.9% lower).
- Isolated process CPU falls from approximately 1.59% to 0.45% of one core for the Live pulse scenario. Short samples are not a battery-life measurement.
- Physical 10 Hz flashing averages 50 ms between on/off edges. Firmware timing is best-effort, not hard real-time.
- Verified signed app/firmware builds, 17 Swift tests, firmware safety/rollover tests, render parity, hardware watchdog/brightness tests, and repeated benchmarks including rainbow-to-preset restoration.

### Upgrade

- Install the v3.0.0 app before flashing MicMatrix v4. Back up and verify the current board flash before replacing it; retain backups outside Git for rollback.
- App release v3.0.0 and firmware wire protocol v4 are distinct versions. Existing MicMatrix v3 firmware remains usable with the new app through streamed frames; older app releases cannot control v4 firmware.
- Saved settings and fresh-install defaults are unchanged from v2.0.1. No Teams API protocol, detection, or menu-bar behavior change is required.
- CLI demos use 5% brightness. The README gallery is static, with the animated version available on demand.

## v2.0.1 — 2026-11-07

- New installs use a 9.0% matrix master brightness, intended for a light-diffusing case. Reduce brightness for exposed LEDs; the 10% safety ceiling is unchanged.
- Live defaults to Dot, Original palette, 100% relative brightness, and Pulse at 1 Hz.
- Muted defaults to Muted microphone, Original palette, 75% relative brightness, and Solid.
- Not in meeting defaults to Adobe A, Original palette, 20% relative brightness, and Solid.
- New matrix status colors use full palette intensity; relative sliders provide the dimming. Matrix enablement is still opt-in.
- Existing saved settings are preserved. Older settings without relative brightness retain 100% multipliers.
- CLI demos remain at 2% brightness, independently of the new-install master.
- Reorganized the README hardware section and moved detailed setup, safety, calibration, protocol, and hardware testing to the [matrix guide](MATRIX.md).

## v2.0.0 — 2026-11-07

### Added

- Waveshare ESP32-S3-Matrix support through native USB-C serial, with pinned custom Arduino firmware; no Wi-Fi required.
- Full-color 64-pixel frames, automatic accelerometer orientation, exclusive serial access, acknowledgements, reconnect, and a three-second stale-display watchdog.
- A 16-choice visual icon gallery: red Live mic, green Muted mic/red slash, fire, red No sign, check, red dot, orientation arrow, red/yellow Warning, heart, Adobe A, rainbow, headphones, moon, AFK cycle, yellow smiley, and right-to-left scrolling shrug.
- Animated chooser/hero previews and a deterministic SVG gallery with 48 boards.
- Three adjacent status cards with palette/tint/single-color selection, Display, Test, and continuous relative brightness controls.
- Gamma-2.2 LED color correction; 1–10% master brightness, 2% default, firmware maximum 25/255. Per-status 0–100% multipliers allow dimming below the master's floor; zero is off.
- Bespoke full-panel call-start rainbow flow with automatic status restoration.
- Automatic matrix blanking on lock, inactive session, display sleep, or system sleep when no Live/Muted call is detected; restores on return.
- Existing menu-bar symbols now pulse red for Live, remain green for Muted, and are white otherwise.
- Standalone Swift/C++ regression tests and bounded physical USB tests.

### Changed and fixed

- Corrected RGB byte order and all four physical orientations; retained offset/mirror calibration in a collapsed disclosure.
- Replaced Shield artwork with a shaded red Adobe A while retaining the saved `shield` identifier.
- Replaced the selectable Off tile with Warning; legacy Off settings/CLI commands still work.
- Unavailable now automatically shows a fixed warning at master brightness and has no editable settings card. It means unknown mic detection, not Teams presence.
- Settings previews normalize color intensity instead of inheriting the Muted color's dimming; actual LED output is unchanged by preview normalization.
- Preserved saved output settings, including Busylight configuration, legacy palette modes, and master brightness. New nonzero brightness values below 1% normalize to the master floor.
- Replaced a hanging timeline-driven menu-bar pulse with a bounded timer, verified with Live/Muted transitions on the running app.

### Upgrade and safety

Use the [README setup and upgrade instructions](README.md). Back up and verify the original board flash before replacing it; keep backups outside Git with restrictive permissions. The app requires MicMatrix's `MATRIX 3 8 8 25` handshake.

The brightness ceiling is a precaution, not a thermal guarantee. Avoid prolonged full-panel white and unplug unusually hot hardware. Low LED precision can cause color steps or make very dim pixels disappear. During actual system sleep, USB updates stop and firmware clears stale output.

### Verification

- 15 standalone Swift tests plus C++ protocol, orientation, reflection, and exhaustive brightness tests.
- Signed release build and installed-binary comparison.
- Physical device tests for frame transport, brightness limits, gamma, watchdog, and animations.
- User-verified orientation, call-start restoration, screen lock/unlock blanking, and timer-driven menu-bar pulse.

## v1.0.0

Initial macOS Teams mute indicator with Teams API/Accessibility detection, Kuando Busylight and BlinkStick USB HID outputs, Home Assistant, webhook/WLED, per-output colors/brightness, effects, and stable local signing.
