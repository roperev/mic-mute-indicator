import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            LightsTab().tabItem { Label("Lights", systemImage: "lightbulb.2") }
            EffectsTab().tabItem { Label("Effects", systemImage: "sparkles") }
            AdvancedTab().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 760, height: 680)
    }
}

// MARK: - Shared pieces

private func colorBinding(_ b: Binding<RGB>) -> Binding<Color> {
    Binding(get: { b.wrappedValue.color }, set: { b.wrappedValue = RGB(color: $0) })
}

/// The states a user actually configures colors for (Unavailable is rare and defaults to off).
private let configurableStates: [MicState] = [.unmuted, .muted, .notInMeeting]

private struct StatusDot: View {
    let ok: Bool
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

struct StateColorsEditor: View {
    @Binding var config: OutputConfig
    var maximumBrightness: Double = 1

    var body: some View {
        ForEach(configurableStates) { state in
            HStack {
                ColorPicker(state.label, selection: colorBinding($config.colors[state]), supportsOpacity: false)
                if config.colors[state].isOff {
                    Text("Off").font(.caption).foregroundStyle(.secondary)
                } else {
                    Button("Turn off") { config.colors[state] = .off }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        LabeledContent("Brightness") {
            HStack {
                Slider(value: $config.brightness, in: LightBrightness.minimum...maximumBrightness)
                Text(maximumBrightness < 1 ? String(format: "%.1f%%", config.brightness * 100) : "\(Int(config.brightness * 100))%")
                    .monospacedDigit().frame(width: maximumBrightness < 1 ? 50 : 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - General

struct GeneralTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: c.symbol(for: c.micState))
                        .font(.system(size: 28))
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.statusHeadline).font(.headline)
                        Text(c.micState == .unknown && !c.detail.isEmpty ? c.detail : "Watching Microsoft Teams")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Pause", isOn: $c.paused).toggleStyle(.switch).labelsHidden()
                        .help("Pause lights")
                }
                .padding(.vertical, 4)
            }

            if let problem = c.problem {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(problem.message)
                        Spacer()
                        switch problem {
                        case .needsAccessibility:
                            Button("Grant Access…") { c.requestAccessibility() }
                            if c.isBundled { Button("Relaunch") { c.relaunch() } }
                        case .noLightsEnabled, .lightDisconnected:
                            EmptyView()
                        }
                    }
                    switch problem {
                    case .needsAccessibility:
                        Caption("Teams Mute Light reads the Teams mute button through Accessibility. Turn it on in System Settings › Privacy & Security › Accessibility, then relaunch. If it's already on, remove the entry with – and grant it again.")
                    case .noLightsEnabled:
                        Caption("Turn on a light in the Lights tab.")
                    case .lightDisconnected:
                        Caption("Plug the light in. It will pick up automatically.")
                    }
                }
            }

            Section {
                Toggle("Launch at login", isOn: $c.launchAtLogin)
                Toggle("Rainbow sweep when a call starts", isOn: $c.settings.callStartRainbow)
            }

            Section {
                LabeledContent("Version", value: c.appVersion)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Lights

struct LightsTab: View {
    @EnvironmentObject var c: AppController

    private var kuandos: [HIDDeviceInfo] { c.hidDevices.filter(\.isKuando) }
    private var sticks: [HIDDeviceInfo] { c.hidDevices.filter(\.isBlinkStick) }

    var body: some View {
        Form {
            Section {
                Toggle("Kuando Busylight", isOn: $c.settings.kuando.enabled)
                if c.settings.kuando.enabled {
                    StatusDot(ok: c.kuando.connectedDevice != nil, text: c.kuando.statusText)
                    devicePicker(selection: $c.settings.kuando.deviceSerial, devices: kuandos)
                    StateColorsEditor(config: $c.settings.kuando)
                    LabeledContent("Color scheme") {
                        Menu("Presets") {
                            Button("Mute light — off when idle, red when live") { c.applyMuteLightPreset() }
                            Button("Busylight only — green / amber / red") { c.applyKuandoOnlyPreset() }
                        }
                        .fixedSize()
                    }
                    Caption("Quit the kuando app while this is on. The two can't share the light.")
                }
            }

            Section {
                Toggle("BlinkStick", isOn: $c.settings.blinkStick.enabled)
                if c.settings.blinkStick.enabled {
                    StatusDot(ok: c.blinkStick.connectedDevice != nil, text: c.blinkStick.statusText)
                    devicePicker(selection: $c.settings.blinkStick.deviceSerial, devices: sticks)
                    Stepper("LEDs: \(c.settings.blinkStickLEDCount)", value: $c.settings.blinkStickLEDCount, in: 1...64)
                    StateColorsEditor(config: $c.settings.blinkStick)
                }
            }

            Section {
                Toggle("Waveshare ESP32-S3 Matrix (USB)", isOn: $c.settings.matrix.light.enabled)
                if c.settings.matrix.light.enabled {
                    StatusDot(ok: c.matrix.statusText.hasPrefix("OK"), text: c.matrix.statusText)
                    Picker("Device", selection: $c.settings.matrix.light.deviceSerial) {
                        Text("First Espressif device").tag("")
                        ForEach(c.matrix.devices) { d in
                            Text(d.displayName).tag(d.serial)
                        }
                        if !c.settings.matrix.light.deviceSerial.isEmpty,
                           !c.matrix.devices.contains(where: { $0.serial == c.settings.matrix.light.deviceSerial }) {
                            Text("Disconnected: \(c.settings.matrix.light.deviceSerial)").tag(c.settings.matrix.light.deviceSerial)
                        }
                    }
                    MatrixStatusEditor(config: $c.settings.matrix) { c.preview($0) }
                    Caption("Unavailable automatically shows the warning exclamation point at master brightness. Use Display to turn individual statuses off.")
                    LabeledContent("Master matrix brightness") {
                        HStack {
                            Slider(value: $c.settings.matrix.light.brightness, in: LightBrightness.minimum...MatrixFrame.maxLevel)
                            Text(String(format: "%.1f%%", c.settings.matrix.light.brightness * 100))
                                .monospacedDigit().frame(width: 50)
                        }
                        Caption("Status brightness is relative to the master: 50% of a 2% master is about 1% output. 0% turns that status off. Very low levels may disappear due to LED precision. The call-start rainbow uses the master only.")
                        Caption("Gamma-corrected LED colors reduce washout as brightness increases. Intentional artwork highlights are preserved.")
                    }
                    DisclosureGroup("Orientation calibration") {
                        Picker("Offset", selection: $c.settings.matrix.rotation) {
                            ForEach(0..<4) { Text("\($0 * 90) degrees").tag($0) }
                        }
                        Toggle("Mirror", isOn: $c.settings.matrix.mirrored)
                        Caption("Automatic rotation is always on. Adjust these only if the graphics are not upright; lying flat retains the last orientation.")
                    }
                    Caption("USB firmware v3. Default brightness 2%, maximum 10%. The display clears on pause, quit, or after 3 seconds without updates. Test buttons preview all enabled lights.")
                }
            }

            Section {
                Toggle("Home Assistant light", isOn: $c.settings.homeAssistant.light.enabled)
                if c.settings.homeAssistant.light.enabled {
                    TextField("Server", text: $c.settings.homeAssistant.baseURL, prompt: Text("http://homeassistant.local:8123"))
                    TextField("Entity", text: $c.settings.homeAssistant.entityID, prompt: Text("light.mic_status"))
                    SecureField("Access token", text: $c.homeAssistantToken)
                    HStack {
                        StatusDot(ok: c.homeAssistant.statusText.hasPrefix("OK"), text: c.homeAssistant.statusText)
                        Spacer()
                        Button("Test") { c.testHomeAssistant() }
                    }
                    StateColorsEditor(config: $c.settings.homeAssistant.light)
                    Caption("Create a long-lived access token in Home Assistant under Profile › Security. It's stored in your Keychain.")
                }
            }

            Section {
                Toggle("Webhook / WLED", isOn: $c.settings.webhook.light.enabled)
                if c.settings.webhook.light.enabled {
                    TextField("URL", text: $c.settings.webhook.url, prompt: Text("http://192.168.1.50/json/state"))
                    Picker("Format", selection: $c.settings.webhook.format) {
                        ForEach(WebhookFormat.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        StatusDot(ok: c.webhook.statusText.hasPrefix("OK"), text: c.webhook.statusText)
                        Spacer()
                        Button("Test") { c.testWebhook() }
                    }
                    StateColorsEditor(config: $c.settings.webhook.light)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func devicePicker(selection: Binding<String>, devices: [HIDDeviceInfo]) -> some View {
        if devices.count > 1 {
            Picker("Device", selection: selection) {
                Text("First found").tag("")
                ForEach(devices) { d in Text(d.displayName).tag(d.serial) }
            }
        }
    }
}

// MARK: - Effects

struct EffectsTab: View {
    @EnvironmentObject var c: AppController

    var body: some View {
        Form {
            Section {
                ForEach(configurableStates) { state in
                    EffectRow(state: state, effect: $c.settings.effects[state]) { c.preview(state) }
                }
            } header: {
                Text("Patterns")
            } footer: {
                Caption("Patterns play on USB lights. Network lights show the solid color.")
            }

            Section("Call start") {
                Toggle("Rainbow sweep when a call starts", isOn: $c.settings.callStartRainbow)
                LabeledContent("Duration") {
                    HStack {
                        Slider(value: $c.settings.rainbowDuration, in: 0.5...5, step: 0.1)
                        Text(String(format: "%.1f s", c.settings.rainbowDuration)).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button("Preview") { c.testRainbow() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct EffectRow: View {
    let state: MicState
    @Binding var effect: StateEffect
    let onPreview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(state.label)
                Spacer()
                Picker("", selection: $effect.effect) {
                    ForEach(LightEffect.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button(action: onPreview) { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Preview")
            }
            if effect.effect != .solid {
                HStack {
                    Text("Speed").font(.callout).foregroundStyle(.secondary)
                    Slider(value: $effect.rateHz, in: 0.25...4, step: 0.25)
                    Text(String(format: "%.2g Hz", effect.rateHz)).font(.callout).monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Advanced

struct AdvancedTab: View {
    @EnvironmentObject var c: AppController
    @ObservedObject private var log = EventLog.shared

    var body: some View {
        Form {
            Section {
                Picker("Detect mute state by", selection: $c.settings.detection) {
                    ForEach([DetectionMode.accessibility, .auto, .teamsAPI]) { Text($0.label).tag($0) }
                }
            } footer: {
                Caption("The Teams local API needs Teams › Settings › Privacy › Third-party app API, which many Teams builds and organizations don't offer.")
            }

            if c.settings.detection != .accessibility {
                Section("Teams local API") {
                    StatusDot(ok: c.api.status == .paired, text: c.api.status.rawValue)
                    HStack {
                        if c.api.status == .connected && c.api.canPair {
                            Button("Pair…") { c.teamsAPI.pair() }
                                .help("Join a meeting first. Teams asks you to allow the connection; pairing toggles mute once.")
                        }
                        Spacer()
                        Button("Forget Pairing") { c.teamsAPI.forgetPairing() }
                    }
                }
            }

            if c.settings.detection != .teamsAPI {
                Section {
                    DisclosureGroup("Mute button matching") {
                        TextField("Muted when label matches", text: $c.settings.axMutedPattern)
                            .font(.body.monospaced())
                        TextField("Live when label matches", text: $c.settings.axUnmutedPattern)
                            .font(.body.monospaced())
                        if let e = c.patternError { Text(e).foregroundStyle(.red).font(.caption) }
                        LabeledContent("Check every") {
                            HStack {
                                Slider(value: $c.settings.axPollInterval, in: 0.2...2, step: 0.1)
                                Text(String(format: "%.1f s", c.settings.axPollInterval)).monospacedDigit().frame(width: 40)
                            }
                        }
                        LabeledContent("Last seen", value: c.ax.detail)
                        HStack {
                            Button("Restore Defaults") { c.resetDetectionPatterns() }
                            Spacer()
                            Button("Export Teams Button List…") { c.dumpAccessibilityTree() }
                        }
                        Caption("Regular expressions matched against the Teams mic button label. The label names the action, so “Unmute mic” means you're muted.")
                    }
                }
            }

            Section {
                DisclosureGroup("Diagnostics") {
                    LabeledContent("Accessibility", value: c.axTrusted ? "Granted" : "Not granted")
                    LabeledContent("Detection source", value: c.source)
                    LabeledContent("Code signature", value: c.signingSummary)
                    LabeledContent("Location", value: Bundle.main.bundlePath)
                    ScrollView {
                        Text(log.text.isEmpty ? "No events yet." : log.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 160)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        Button("Copy Log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(log.text, forType: .string)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
