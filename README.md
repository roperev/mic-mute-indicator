# Teams Mute Light

A small macOS menu bar app that shows whether **Microsoft Teams** has you **muted or unmuted**, not just whether the mic is active, on a USB LED or a Home Assistant light.

- **Detection:** the Teams local API (official, event-driven) with an automatic fallback to reading the Teams mic button through the macOS Accessibility API.
- **Outputs:** Kuando Busylight, BlinkStick (Nano/Strip/…), Home Assistant light entity, generic webhook, or WLED. You can turn on any combination.
- **Modes:**
  - **Companion:** your Kuando Busylight keeps running on its own software for meeting/presence, and a second light (BlinkStick, HA, WLED) shows mute state.
  - **Kuando-only:** this app drives the Busylight itself: green = available, amber = in a meeting and muted, red = live.
- Per-light colors and brightness, a device picker, launch at login, and pause/test from the menu.

## Requirements

- macOS 14 or later (built and targeted for your macOS 26 machine)
- Xcode or the Command Line Tools (`xcode-select --install`), which gives you `swift`
- New Microsoft Teams (`com.microsoft.teams2`). Classic Teams is detected for the Accessibility fallback only.

## Build and run

```bash
cd mic-mute-indicator
chmod +x build.sh scripts/*.sh
./scripts/create-signing-cert.sh   # once: stable signature so Accessibility grants stick
./build.sh --install --run         # builds, signs, copies to /Applications, launches
```

A mic icon shows up in the menu bar. Open **Settings…** from it.

The icon is a status beacon, deliberately not a mic, so it doesn't get confused with macOS's own mic indicator.

| Icon | Meaning |
|---|---|
| `light.beacon.min` (outline) | Not in a call / Teams not running |
| `light.beacon.min.fill` | In a call, muted |
| `light.beacon.max.fill` (with rays) | **Live — mic is on** |
| `lightbulb.slash` | Can't read Teams (e.g. Accessibility not granted) |
| `pause.circle` | Lights paused |

Settings has four tabs:
- **General:** status, anything that needs fixing, launch at login.
- **Lights:** each light with its colors and brightness.
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

If **Third-party app API** isn't on your Privacy page, your Teams build or your org doesn't expose it. That's common on current new-Teams builds and managed tenants. Some people get it back by signing out of Teams and back in; otherwise ask IT. To confirm, `lsof -nP -iTCP:8124 -sTCP:LISTEN` prints nothing when the API is off. In that case set **Settings › Detection** to **Accessibility only**. Auto mode works either way; it just keeps retrying the API quietly in the background.

### 2. Accessibility fallback

Grant **System Settings › Privacy & Security › Accessibility** to *Teams Mute Light* (the app prompts you). The app finds the meeting mic button, preferring DOM id `microphone-button`, and reads its label:

- "Unmute mic" / "Unmute (⌘+Shift+M)" means you are **muted**.
- "Mute mic" / "Mute (⌘+Shift+M)" means you are **unmuted**.

Both regexes can be edited in **Settings › Detection**. If Teams changes its labels or runs in another language, run **Dump Teams Accessibility Tree…** during a meeting and adjust them. Full-tree scans are throttled while you're not in a meeting (about every 2 s if any mic is in use, 10 s otherwise). Once the button is found, only that element is re-read, every 0.5 s.

> **Do this once:** `./scripts/create-signing-cert.sh`. macOS ties the Accessibility grant to the app's code signature. Ad-hoc signatures change on every build, so the toggle in System Settings can be on while the app still sees "Not granted". The script creates a local self-signed "TeamsMuteLight Local" identity, which `build.sh` then uses automatically, so grants survive rebuilds.
>
> **Fixing a stale grant:** in System Settings › Privacy & Security › Accessibility, remove *every* Teams Mute Light / TeamsMuteLight entry with **–**. Don't add the inner `Contents/MacOS/TeamsMuteLight` binary: the entry must be the `.app`. Then click **Grant…** in the app, switch the new entry on, and click **Relaunch**. As a last resort, `tccutil reset Accessibility com.eroper.TeamsMuteLight` wipes the entry.

## Hardware and outputs

| Output | How it talks | Notes |
|---|---|---|
| **Kuando Busylight** (Alpha/Omega/UC/…) | USB HID, 64-byte output report, keep-alive every 5 s | VID `27BB` (+ legacy `04D8:F848`). Quit kuando's software first. |
| **BlinkStick** (Nano, Strip, Square) | USB HID feature reports 1 & 5 | VID:PID `20A0:41E5`. Nano = 2 LEDs (set "LEDs to light"). |
| **Home Assistant** | `POST /api/services/light/turn_on` / `turn_off` | Long-lived token in Keychain. Any RGB light entity (Hue, Zigbee bulb, ESPHome LED…). |
| **Webhook – Generic** | `POST {"state","color","r","g","b","brightness"}` | Node-RED, HA webhook automations, your own ESP32 sketch. |
| **Webhook – WLED** | `POST http://<ip>/json/state` | Cheapest DIY: ESP32/ESP8266 + a WS2812 LED + WLED firmware. |

DIY options if you'd rather not buy a BlinkStick:
- **ESP32 + WLED + one WS2812B LED:** no code to write. Flash WLED from the web installer and point the webhook at `http://<ip>/json/state` in WLED format.
- **BlinkStick-compatible DIY:** BlinkStick firmware is open source (ATtiny85/V-USB). A Digispark clone with BlinkStick firmware shows up as `20A0:41E5` and works with the BlinkStick output.
- **Home Assistant:** any smart RGB bulb or ESPHome light already in HA works with the HA output.

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
  CLI.swift                   devices / kuando / blinkstick / cycle / ax-dump / watch
  Detection/TeamsAPIMonitor.swift      ws://127.0.0.1:8124 client (protocol 2.0.0)
  Detection/AccessibilityMonitor.swift AX mic-button reader + CoreAudio hint
  Outputs/HIDDeviceManager.swift       IOHIDManager hot-plug for USB lights
  Outputs/KuandoLight.swift            Busylight protocol + keep-alive
  Outputs/BlinkStickLight.swift
  Outputs/NetworkLights.swift          Home Assistant + Webhook/WLED
  UI/MenuContent.swift, UI/SettingsView.swift
```

Hacking: `swift build && .build/debug/TeamsMuteLight` runs it unbundled for quick iteration. Launch at login needs the bundled `.app`, though.

## Troubleshooting

- **Busylight flickers or changes on its own:** the kuando software is still running. Quit it, or turn this app's Kuando output off.
- **Busylight goes dark after ~30 s:** the keep-alive isn't reaching it. Check **Settings › Log** for write errors.
- **"Teams API: Not connected":** the API isn't enabled in Teams, Teams isn't running, or your org blocks it. Auto mode falls back to Accessibility.
- **Pair menu item missing:** you only see it while you're *in a meeting* and the API reports `canPair`.
- **Always "No meeting mic button found":** run the AX dump during a meeting and update the regexes, or send me the dump.
- **Home Assistant over plain `http://` to a non-`.local` hostname is blocked:** use HTTPS, an IP address, or `homeassistant.local` (ATS only allows local-network HTTP).

## References

- Teams local API protocol notes: [svrooij/teams-monitor](https://github.com/svrooij/teams-monitor)
- Kuando HID protocol reference: [yaddran/busylight](https://github.com/yaddran/busylight)
- Inspiration: [leonardodino/BeezyLight](https://github.com/leonardodino/BeezyLight)
