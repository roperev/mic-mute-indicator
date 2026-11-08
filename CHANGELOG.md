# Release notes

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
