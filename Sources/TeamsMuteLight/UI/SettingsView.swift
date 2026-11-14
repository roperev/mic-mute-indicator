import SwiftUI

private final class SettingsNavigation: ObservableObject {
    @Published var tab = 0
}

struct SettingsView: View {
    var selectedTab: Binding<Int>?
    var expandAdvancedDetails = false
    @StateObject private var navigation = SettingsNavigation()

    var body: some View {
        TabView(selection: selectedTab ?? $navigation.tab) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            LightsTab().tabItem { Label("Lights", systemImage: "lightbulb.2") }.tag(1)
            EffectsTab().tabItem { Label("Effects", systemImage: "sparkles") }.tag(2)
            AdvancedTab(expandDetails: expandAdvancedDetails)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }.tag(3)
        }
        .frame(width: 760, height: 1030)
    }
}

// MARK: - Shared pieces

/// Unavailable has a fixed matrix warning rather than an editable status card.
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
                Text(state.label)
                Spacer()
                ColorSwatchPicker(selection: $config.colors[state], label: "\(state.label) color")
                if !config.colors[state].isOff {
                    Button("Turn off") { config.colors[state] = .off }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
        LabeledContent("Brightness") {
            HStack {
                Slider(value: $config.brightness, in: LightBrightness.minimum...maximumBrightness)
                    .labelsHidden()
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
                }
                .padding(.vertical, 4)
                Toggle("Pause lights", isOn: $c.paused)
                    .toggleStyle(.switch)
                    .help("Temporarily stop light output without changing your settings")
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

            Section("Startup") {
                Toggle("Launch at login", isOn: $c.launchAtLogin)
            }

            FirmwareManagementView(manager: c.firmware)

            Section {
                EmptyView()
            } footer: {
                HStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 16) {
                        Text("About").font(.subheadline).foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            Text("Teams Mute Light").font(.title2.bold())
                            Text("Microsoft Teams mute status for USB and network lights.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        Divider()
                        Text("Version \(c.appVersion) (build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"))")
                            .font(.callout)
                            .textSelection(.enabled)
                        Text("roperev/mic-mute-indicator")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Link(destination: URL(string: "https://github.com/roperev/mic-mute-indicator")!) {
                            Label("View project on GitHub", systemImage: "arrow.up.right.square")
                        }
                        .font(.body)
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .padding(24)
                    .frame(width: 540)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
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
            matrixSection
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

    private var matrixSection: some View {
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
                LabeledContent {
                    HStack {
                        Slider(value: $c.settings.matrix.light.brightness, in: LightBrightness.minimum...MatrixFrame.maxLevel)
                            .labelsHidden()
                        Text(String(format: "%.1f%%", c.settings.matrix.light.brightness * 100))
                            .monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("Master Matrix Brightness")
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                            .help("Each state's brightness scales this master level: 50% of a 2% master is about 1% output. A state at 0% is off. Very dim pixels may disappear due to LED precision. The call-start rainbow uses the master level only. Start lower on exposed LEDs; the 10% ceiling is not a thermal guarantee.")
                            .accessibilityLabel("About master matrix brightness")
                    }
                }
                HStack(spacing: 16) {
                    Text("Orientation").fixedSize()
                    Picker("Orientation", selection: $c.settings.matrix.rotation) {
                        ForEach(0..<4) { Text("\($0 * 90)°").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                    .help("Offset from automatic gravity alignment. When lying flat, the matrix retains its last orientation.")
                    Spacer(minLength: 0)
                    Text("Mirror").fixedSize()
                    Toggle("Mirror", isOn: $c.settings.matrix.mirrored)
                        .toggleStyle(.switch).controlSize(.small)
                        .labelsHidden()
                        .frame(width: 36)
                        .accessibilityLabel("Mirror horizontally")
                        .help("Mirror artwork horizontally before orientation is applied")
                }
                Caption("Unavailable shows a fixed warning. Test previews all enabled lights for three seconds.")
            }
        }
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
                Text("Status effects")
            } footer: {
                Caption("Effects play on USB lights. Network outputs keep their solid status color. Test previews a state on all enabled lights.")
            }

            Section {
                HStack {
                    Toggle("Play rainbow when a call starts", isOn: $c.settings.callStartRainbow)
                    Spacer()
                    Button("Test rainbow") { c.testRainbow() }
                        .help("Preview the rainbow on enabled USB lights, even when automatic playback is off")
                }
                LabeledContent("Duration") {
                    HStack {
                        Slider(value: $c.settings.rainbowDuration, in: 0.5...5, step: 0.1)
                            .labelsHidden()
                        Text(String(format: "%.1f s", c.settings.rainbowDuration))
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                    .disabled(!c.settings.callStartRainbow)
                }
            } header: {
                Text("Call-start rainbow")
            } footer: {
                Caption("A temporary rainbow sweep plays when you enter a call, then restores the current status. Enabled by default on new installs.")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(state.label).font(.headline)
                Spacer()
                Button("Test", action: onPreview)
                    .accessibilityLabel("Test \(state.label) effect")
                    .help("Preview this state on all enabled lights for three seconds")
            }
            Picker("Effect", selection: $effect.effect) {
                ForEach(LightEffect.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("\(state.label) effect")
            if effect.effect != .solid {
                HStack(spacing: 12) {
                    Text("Rate").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    Slider(value: $effect.rateHz, in: 0.25...4, step: 0.25)
                        .labelsHidden()
                        .accessibilityLabel("\(state.label) cycles per second")
                        .help("Cycles per second: 1 Hz completes one pulse or flash each second")
                    Text(String(format: "%.2g Hz", effect.rateHz)).monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Advanced

private final class AdvancedPresentation: ObservableObject {
    @Published var matching: Bool
    @Published var diagnostics: Bool

    init(expanded: Bool) {
        matching = expanded
        diagnostics = expanded
    }
}

struct AdvancedTab: View {
    @EnvironmentObject var c: AppController
    @ObservedObject private var log = EventLog.shared
    @StateObject private var presentation: AdvancedPresentation

    init(expandDetails: Bool = false) {
        _presentation = StateObject(wrappedValue: AdvancedPresentation(expanded: expandDetails))
    }

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
                    DisclosureGroup("Teams microphone button matching", isExpanded: $presentation.matching) {
                        Text("Reads the meeting microphone button in Teams, not system-wide microphone activity. Its label describes an action: “Unmute mic” means you are muted; “Mute mic” means you are live.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Caption("These case-insensitive regular expressions are a fallback for identifying button labels. The defaults usually work; change them only if Teams uses different wording.")
                        TextField("Muted: button offers to unmute", text: $c.settings.axMutedPattern)
                            .font(.body.monospaced())
                        TextField("Live: button offers to mute", text: $c.settings.axUnmutedPattern)
                            .font(.body.monospaced())
                        if let e = c.patternError { Text(e).foregroundStyle(.red).font(.caption) }
                        Picker("Update interval", selection: $c.settings.axPollInterval) {
                            ForEach([0.2, 0.3, 0.5, 1, 2, 5], id: \.self) { interval in
                                Text(String(format: "%.1f seconds", interval)).tag(interval)
                            }
                            if ![0.2, 0.3, 0.5, 1, 2, 5].contains(c.settings.axPollInterval) {
                                Text(String(format: "%.2g seconds (current)", c.settings.axPollInterval))
                                    .tag(c.settings.axPollInterval)
                            }
                        }
                        Caption("Shorter intervals respond faster; longer intervals reduce polling. This applies only to Accessibility detection, not the paired Teams API.")
                        LabeledContent("Last seen", value: c.ax.detail)
                            .textSelection(.enabled)
                        HStack {
                            Button("Restore Defaults") { c.resetDetectionPatterns() }
                            Spacer()
                            Button("Export Teams Button List…") { c.dumpAccessibilityTree() }
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Diagnostics", isExpanded: $presentation.diagnostics) {
                    LabeledContent("Accessibility", value: c.axTrusted ? "Granted" : "Not granted")
                    LabeledContent("Detection source", value: c.source)
                    LabeledContent("Code signature") {
                        Text(c.signingSummary).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    LabeledContent("Location") {
                        Text(Bundle.main.bundlePath)
                            .font(.caption.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Text("Event log").font(.subheadline.bold())
                        Spacer()
                        Button("Copy Log") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(log.text, forType: .string)
                        }
                    }
                    ScrollView {
                        Text(log.text.isEmpty ? "No events yet." : log.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: 160)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .formStyle(.grouped)
    }
}
