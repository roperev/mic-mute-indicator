import AppKit
import Darwin
import Combine
import Security
import ServiceManagement
import SwiftUI

private struct AnimationBenchmarkRow: Encodable {
    let scenario: String
    let seconds: Double
    let cpuSeconds: Double
    let cpuPercentOfOneCore: Double
    let animationTicks: Int
    let renderedFrames: Int
    let usb: MatrixLight.Measurement
}

/// Ties detection to outputs. Main thread only.
final class AppController: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            guard !isolatedMeasurement else { return }
            settings.save()
            settingsChanged(from: oldValue)
        }
    }

    @Published private(set) var micState: MicState = .unknown
    @Published private(set) var source = "—"
    @Published private(set) var detail = ""
    @Published private(set) var api = TeamsAPIMonitor.Snapshot()
    @Published private(set) var ax = AccessibilityMonitor.Reading(state: .unknown, detail: "Starting…")
    @Published private(set) var axTrusted = AccessibilityMonitor.isTrusted
    @Published private(set) var hidDevices: [HIDDeviceInfo] = []
    @Published private(set) var patternError: String?
    @Published var paused = false {
        didSet {
            if paused != oldValue {
                updateMenuBarPulse()
                pushLights()
            }
        }
    }
    @Published private(set) var menuBarPulseTime: TimeInterval = 0
    @Published private(set) var previewState: MicState?
    @Published var homeAssistantToken: String {
        didSet {
            guard homeAssistantToken != oldValue else { return }
            Keychain.set(homeAssistantToken, for: .homeAssistantToken)
            homeAssistant.token = homeAssistantToken
        }
    }

    let teamsAPI = TeamsAPIMonitor()
    let axMonitor = AccessibilityMonitor()
    let kuando = KuandoLight()
    let blinkStick = BlinkStickLight()
    let matrix = MatrixLight()
    let homeAssistant = HomeAssistantLight()
    let webhook = WebhookLight()

    private var axRunning = false
    private var previewWork: DispatchWorkItem?
    private var trustTimer: Timer?
    private var statusTimer: Timer?
    private var tokens: [NSObjectProtocol] = []
    private var screenLockTokens: [NSObjectProtocol] = []
    private var matrixAvailability = MatrixDisplayAvailability()
    private var matrixAutomaticallyBlanked = false
    private var menuBarPulseTimer: Timer?
    private let isolatedMeasurement: Bool
    private var animationTicks = 0
    private var renderedFrames = 0

    static func runAnimationBenchmark(seconds: Double, serial: String) throws {
        var configuration = AppSettings()
        configuration.kuando.enabled = false
        configuration.blinkStick.enabled = false
        configuration.homeAssistant.light.enabled = false
        configuration.webhook.light.enabled = false
        configuration.matrix.light.enabled = false
        configuration.matrix.light.deviceSerial = serial
        configuration.matrix.light.brightness = MatrixFrame.demoLevel
        configuration.matrix.light.colors = StateColors(notInMeeting: .red, muted: .green,
            unmuted: .red, unknown: .red)
        configuration.matrix.brightnessLevels = .legacy
        let controller = AppController(measurementSettings: configuration)
        defer { controller.shutdown() }
        let scenarios: [(String, Bool, MicState, MatrixIcon, LightEffect, Double, Bool)] = [
            ("disabled-pulse", false, .notInMeeting, .dot, .pulse, 1, false),
            ("matrix-solid", true, .muted, .dot, .solid, 1, false),
            ("matrix-pulse-1hz", true, .unmuted, .dot, .pulse, 1, false),
            ("matrix-flash-1hz", true, .muted, .dot, .flash, 1, false),
            ("matrix-flash-10hz", true, .muted, .dot, .flash, 10, false),
            ("matrix-afk-solid", true, .muted, .afk, .solid, 1, false),
            ("matrix-shrug-solid", true, .muted, .shrug, .solid, 1, false),
            ("locked-matrix-pulse", true, .notInMeeting, .dot, .pulse, 1, true),
        ]
        var rows: [AnimationBenchmarkRow] = []
        func runLoop(for duration: Double) {
            let until = ProcessInfo.processInfo.systemUptime + duration
            while ProcessInfo.processInfo.systemUptime < until {
                RunLoop.main.run(until: Date().addingTimeInterval(
                    min(0.02, until - ProcessInfo.processInfo.systemUptime)))
            }
        }
        for (name, enabled, state, icon, effect, rate, locked) in scenarios {
            controller.stopAnimation()
            controller.matrix.release()
            controller.matrixAutomaticallyBlanked = false
            controller.settings.matrix.light.enabled = enabled
            controller.settings.matrix.icons[state] = icon
            controller.settings.effects[state] = StateEffect(effect: effect, rateHz: rate)
            controller.micState = state
            controller.matrixAvailability = MatrixDisplayAvailability(locked: locked)
            controller.configureOutputs()
            controller.updateMenuBarPulse()
            controller.phaseStart = Date()
            controller.pushLights()
            // Exclude discovery/handshake and previous-frame draining from steady-state samples.
            runLoop(for: 1.5)
            if name == "matrix-pulse-1hz", controller.matrix.supportsPresets {
                controller.playRainbow(sweeps: 1, blackout: 0.1)
                runLoop(for: controller.settings.rainbowDuration + 0.5)
                guard controller.animationTimer == nil else {
                    throw NSError(domain: "AnimationBenchmark", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Host animation did not stop after rainbow restoration"])
                }
            }
            if enabled && !locked && !controller.matrix.statusText.hasPrefix("OK") {
                throw NSError(domain: "AnimationBenchmark", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "\(name): \(controller.matrix.statusText)"])
            }
            let before = controller.matrix.measurement()
            let ticks = controller.animationTicks
            let renders = controller.renderedFrames
            let cpuStart = clock()
            let start = ProcessInfo.processInfo.systemUptime
            runLoop(for: seconds)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
            let after = controller.matrix.measurement()
            if enabled && !locked && !controller.matrix.statusText.hasPrefix("OK") {
                throw NSError(domain: "AnimationBenchmark", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(name): \(controller.matrix.statusText)"])
            }
            rows.append(AnimationBenchmarkRow(scenario: name, seconds: elapsed, cpuSeconds: cpu,
                cpuPercentOfOneCore: cpu / elapsed * 100,
                animationTicks: controller.animationTicks - ticks,
                renderedFrames: controller.renderedFrames - renders,
                usb: MatrixLight.Measurement(transportTicks: after.transportTicks - before.transportTicks,
                    discoveries: after.discoveries - before.discoveries,
                    acknowledgedFrames: after.acknowledgedFrames - before.acknowledgedFrames,
                    transmittedBytes: after.transmittedBytes - before.transmittedBytes)))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(rows))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func updateMenuBarPulse() {
        guard micState == .unmuted && !paused else {
            menuBarPulseTimer?.invalidate()
            menuBarPulseTimer = nil
            menuBarPulseTime = 0
            return
        }
        guard menuBarPulseTimer == nil else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.menuBarPulseTime = ProcessInfo.processInfo.systemUptime - start
        }
        RunLoop.main.add(timer, forMode: .common)
        menuBarPulseTimer = timer
    }

    init(measurementSettings: AppSettings? = nil) {
        isolatedMeasurement = measurementSettings != nil
        settings = measurementSettings ?? AppSettings.load()
        homeAssistantToken = measurementSettings == nil ? (Keychain.get(.homeAssistantToken) ?? "") : ""
        homeAssistant.token = homeAssistantToken
        matrix.onChange = { [weak self] in
            self?.objectWillChange.send()
            self?.pushLights()
        }
        if isolatedMeasurement {
            configureOutputs()
            return
        }

        teamsAPI.onChange = { [weak self] snap in
            self?.api = snap
            self?.updateAXActivity()
            self?.recompute()
        }
        axMonitor.onChange = { [weak self] reading in
            self?.ax = reading
            self?.recompute()
        }
        HIDDeviceManager.shared.addObserver { [weak self] in self?.refreshDevices() }
        refreshDevices()

        configureOutputs()
        configureDetection()
        observeSystem()
        recompute()

        // Re-check Accessibility trust periodically (the user grants it in System Settings).
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let trusted = AccessibilityMonitor.isTrusted
            if trusted != self.axTrusted { self.axTrusted = trusted }
            // Network outputs update their status asynchronously; nudge the UI.
            self.objectWillChange.send()
        }
        RunLoop.main.add(t, forMode: .common)
        trustTimer = t
    }

    // MARK: Menu bar

    /// Status-light icons (deliberately not a mic, to avoid confusion with macOS's own mic indicator).
    /// Falls back to lightbulb symbols if a beacon symbol isn't available on this OS.
    private static func symbol(_ preferred: String, _ fallback: String) -> String {
        NSImage(systemSymbolName: preferred, accessibilityDescription: nil) != nil ? preferred : fallback
    }
    private static let symLive = symbol("light.beacon.max.fill", "lightbulb.fill")
    private static let symMuted = symbol("light.beacon.min.fill", "lightbulb")
    private static let symIdle = symbol("light.beacon.min", "lightbulb")
    private static let symUnavailable = symbol("lightbulb.slash", "questionmark.circle")

    var menuBarSymbol: String { symbol(for: previewState ?? micState) }

    func symbol(for state: MicState) -> String {
        if paused { return "pause.circle" }
        switch state {
        case .unmuted: return Self.symLive
        case .muted: return Self.symMuted
        case .notInMeeting: return Self.symIdle
        case .unknown: return Self.symUnavailable
        }
    }

    /// One-line, human status for the menu and Settings.
    var statusHeadline: String {
        if paused { return "Lights paused" }
        switch micState {
        case .unmuted: return "Live — your mic is on"
        case .muted: return "In a call, muted"
        case .notInMeeting: return "Not in a call"
        case .unknown: return "Can't read Teams"
        }
    }

    enum Problem: Equatable {
        case needsAccessibility
        case noLightsEnabled
        case lightDisconnected(String)

        var message: String {
            switch self {
            case .needsAccessibility: return "Accessibility permission needed"
            case .noLightsEnabled: return "No lights turned on"
            case .lightDisconnected(let name): return "\(name) not connected"
            }
        }
    }

    /// The single most important thing the user should fix, if any.
    var problem: Problem? {
        if settings.detection != .teamsAPI && !axTrusted && api.status != .paired { return .needsAccessibility }
        if activeOutputs.isEmpty { return .noLightsEnabled }
        if settings.kuando.enabled && kuando.connectedDevice == nil { return .lightDisconnected("Busylight") }
        if settings.blinkStick.enabled && blinkStick.connectedDevice == nil { return .lightDisconnected("BlinkStick") }
        if settings.matrix.light.enabled && matrix.connectedDevice == nil { return .lightDisconnected("Waveshare Matrix") }
        return nil
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    func resetDetectionPatterns() {
        let d = AppSettings()
        settings.axMutedPattern = d.axMutedPattern
        settings.axUnmutedPattern = d.axUnmutedPattern
        settings.axPollInterval = d.axPollInterval
    }

    // MARK: Detection

    private func configureDetection() {
        patternError = axMonitor.configure(
            mutedPattern: settings.axMutedPattern,
            unmutedPattern: settings.axUnmutedPattern,
            interval: settings.axPollInterval)
        if settings.detection == .accessibility { teamsAPI.stop() } else { teamsAPI.start() }
        updateAXActivity()
    }

    /// In Auto mode, skip Accessibility polling while the Teams API is paired and delivering state.
    private func updateAXActivity() {
        let want: Bool
        switch settings.detection {
        case .accessibility: want = true
        case .teamsAPI: want = false
        case .auto: want = api.status != .paired
        }
        guard want != axRunning else { return }
        axRunning = want
        if want { axMonitor.start() } else { axMonitor.stop() }
    }

    private func apiReading() -> (MicState, String)? {
        guard api.status == .paired else { return nil }
        if api.isInMeeting == true {
            guard let muted = api.isMuted else { return (.unknown, "In meeting, mute state not reported") }
            return (muted ? .muted : .unmuted, "")
        }
        return (.notInMeeting, "")
    }

    private func recompute() {
        var state = MicState.unknown
        var src = "Accessibility"
        var det = ""
        switch settings.detection {
        case .teamsAPI:
            src = "Teams API"
            if let r = apiReading() { state = r.0; det = r.1 } else { det = api.status.rawValue }
        case .accessibility:
            state = ax.state; det = ax.detail
        case .auto:
            if let r = apiReading() { state = r.0; det = r.1; src = "Teams API" }
            else { state = ax.state; det = ax.detail }
        }
        var callStarted = false
        if micState != state {
            Log.info("Mic state: \(state.label) [\(src)]")
            let wasInCall = micState == .muted || micState == .unmuted
            let nowInCall = state == .muted || state == .unmuted
            callStarted = nowInCall && !wasInCall
            micState = state
            phaseStart = Date()
        }
        if source != src { source = src }
        if detail != det { detail = det }
        updateMenuBarPulse()
        if callStarted && settings.callStartRainbow && !paused {
            Log.info("Call started — rainbow sweep")
            playRainbow()
        } else {
            pushLights()
        }
    }

    // MARK: Outputs

    private struct Active {
        let output: LightOutput
        let config: OutputConfig
    }

    private var activeOutputs: [Active] {
        var list: [Active] = []
        if settings.kuando.enabled { list.append(Active(output: kuando, config: settings.kuando)) }
        if settings.blinkStick.enabled { list.append(Active(output: blinkStick, config: settings.blinkStick)) }
        if settings.matrix.light.enabled { list.append(Active(output: matrix, config: settings.matrix.light)) }
        if settings.homeAssistant.light.enabled { list.append(Active(output: homeAssistant, config: settings.homeAssistant.light)) }
        if settings.webhook.light.enabled { list.append(Active(output: webhook, config: settings.webhook.light)) }
        return list
    }

    private func configureOutputs() {
        kuando.serial = settings.kuando.deviceSerial
        blinkStick.serial = settings.blinkStick.deviceSerial
        blinkStick.ledCount = settings.blinkStickLEDCount
        matrix.serial = settings.matrix.light.deviceSerial
        matrix.icons = settings.matrix.icons
        matrix.rotation = settings.matrix.rotation
        matrix.mirrored = settings.matrix.mirrored
        matrix.fullColor = settings.matrix.fullColor
        matrix.colorStyles = settings.matrix.colorStyles
        matrix.brightnessLevels = settings.matrix.brightnessLevels
        homeAssistant.baseURL = settings.homeAssistant.baseURL
        homeAssistant.entityID = settings.homeAssistant.entityID
        webhook.url = settings.webhook.url
        webhook.format = settings.webhook.format
    }

    // MARK: Effects / animation

    private var animationTimer: Timer?
    /// When the current state (or preview) began; pulse/flash phase is measured from here.
    private var phaseStart = Date()
    private var rainbowStart = Date()
    private var rainbowUntil: Date?

    func pushLights() {
        let now = Date()
        if let until = rainbowUntil, now >= until { rainbowUntil = nil }
        if paused && previewState == nil && rainbowUntil == nil {
            stopAnimation()
            activeOutputs.forEach { $0.output.release() }
            return
        }
        let state = previewState ?? micState
        let needsAnimation = activeOutputs.contains { active in
            if active.output === matrix {
                guard !matrixAvailability.shouldBlank(state: micState) else { return false }
                return rainbowUntil != nil || (matrix.connectedDevice != nil && !matrix.supportsPresets &&
                    (settings.effects[state].effect != .solid || settings.matrix.icons[state].isAnimated))
            }
            return active.output.supportsAnimation &&
                (rainbowUntil != nil || settings.effects[state].effect != .solid)
        }
        if needsAnimation { startAnimation() } else { stopAnimation() }
        renderFrame(state: state, now: now)
    }

    private func renderFrame(state: MicState, now: Date) {
        renderedFrames += 1
        let effect = settings.effects[state]
        let level = Effects.level(effect.effect, rateHz: effect.rateHz, t: now.timeIntervalSince(phaseStart))
        var rainbow: RGB?
        if rainbowUntil != nil {
            let t = now.timeIntervalSince(rainbowStart)
            // Negative t = optional blackout lead-in before the sweep.
            rainbow = t < 0 ? .off
                : Effects.rainbow(t: t, duration: settings.rainbowDuration, sweeps: rainbowSweeps)
        }
        for a in activeOutputs {
            if a.output === matrix {
                if matrixAvailability.shouldBlank(state: micState) {
                    if !matrixAutomaticallyBlanked {
                        matrix.release()
                        matrixAutomaticallyBlanked = true
                        Log.info("Matrix automatically blanked: session locked/inactive or asleep, no active call")
                    }
                    continue
                }
                if matrixAutomaticallyBlanked {
                    Log.info("Matrix automatic blanking ended; restoring current status")
                    matrixAutomaticallyBlanked = false
                }
            }
            let brightness = LightBrightness.clamped(a.config.brightness)
            if a.output === matrix, rainbowUntil != nil {
                matrix.applyRainbow(t: now.timeIntervalSince(rainbowStart),
                    duration: settings.rainbowDuration, sweeps: rainbowSweeps, brightness: brightness)
                continue
            }
            let base = a.config.colors[state]
            if a.output === matrix {
                matrix.applyStatus(state: state, color: base, brightness: brightness,
                    effect: effect, phaseStart: phaseStart, now: now)
                continue
            }
            let color = a.output.supportsAnimation ? (rainbow ?? base.scaled(level)) : base
            a.output.apply(state: state, color: color, brightness: brightness)
        }
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }
        let t = Timer(timeInterval: Effects.frameInterval, repeats: true) { [weak self] _ in
            self?.animationTicks += 1
            self?.pushLights()
        }
        RunLoop.main.add(t, forMode: .common)
        animationTimer = t
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private var rainbowSweeps = 2

    /// Call start: 2 sweeps, no lead-in. Manual test: 1 sweep after a 1 s blackout so the
    /// start of the spectrum is easy to see.
    func playRainbow(sweeps: Int = 2, blackout: TimeInterval = 0) {
        rainbowSweeps = sweeps
        rainbowStart = Date().addingTimeInterval(max(0, blackout))
        rainbowUntil = rainbowStart.addingTimeInterval(max(0.3, min(5, settings.rainbowDuration)))
        pushLights()
    }

    func testRainbow() { playRainbow(sweeps: 1, blackout: 1) }

    private func settingsChanged(from old: AppSettings) {
        if !settings.kuando.enabled && old.kuando.enabled { kuando.release() }
        if !settings.blinkStick.enabled && old.blinkStick.enabled { blinkStick.release() }
        if !settings.matrix.light.enabled && old.matrix.light.enabled { matrix.release() }
        if !settings.homeAssistant.light.enabled && old.homeAssistant.light.enabled { homeAssistant.release() }
        if !settings.webhook.light.enabled && old.webhook.light.enabled { webhook.release() }
        // Switching to a different physical device: turn the old one off first.
        if settings.kuando.deviceSerial != old.kuando.deviceSerial { kuando.release() }
        if settings.blinkStick.deviceSerial != old.blinkStick.deviceSerial { blinkStick.release() }
        if settings.matrix.light.deviceSerial != old.matrix.light.deviceSerial { matrix.release() }

        configureOutputs()

        if settings.detection != old.detection
            || settings.axMutedPattern != old.axMutedPattern
            || settings.axUnmutedPattern != old.axUnmutedPattern
            || settings.axPollInterval != old.axPollInterval {
            configureDetection()
        }
        recompute()
    }

    /// Show a state's colors for 3 seconds.
    func preview(_ state: MicState) {
        previewWork?.cancel()
        previewState = state
        phaseStart = Date()
        pushLights()
        let work = DispatchWorkItem { [weak self] in
            self?.previewState = nil
            self?.pushLights()
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func testHomeAssistant() {
        let c = settings.homeAssistant.light
        homeAssistant.send(color: c.colors[.unmuted], brightness: c.brightness, force: true)
    }

    func testWebhook() {
        let c = settings.webhook.light
        webhook.send(state: .unmuted, color: c.colors[.unmuted], brightness: c.brightness)
    }

    private func refreshDevices() {
        hidDevices = HIDDeviceManager.shared.allInfos
        pushLights()
    }

    // MARK: System

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            matrixAvailability.locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
            matrixAvailability.sessionInactive = (session[kCGSessionOnConsoleKey as String] as? Bool) == false
        } else {
            Log.info("Unable to read initial screen-lock state; waiting for macOS session notifications")
        }
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            screenLockTokens.append(distributed.addObserver(forName: Notification.Name(name),
                object: nil, queue: .main) { [weak self] _ in
                self?.matrixAvailability.locked = locked
                self?.pushLights()
            })
        }
        for (name, inactive) in [(NSWorkspace.sessionDidResignActiveNotification, true),
                                 (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.matrixAvailability.sessionInactive = inactive
                self?.pushLights()
            })
        }
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false)] {
            tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.matrixAvailability.displayAsleep = asleep
                self?.pushLights()
            })
        }
        tokens.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.matrixAvailability.systemAsleep = true
            self?.pushLights()
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier, AccessibilityMonitor.teamsBundleIDs.contains(id) else { return }
            Log.info("Teams launched")
            // Give Teams a few seconds to open its local API port.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.teamsAPI.reconnectNow() }
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.matrixAvailability.systemAsleep = false
            self?.teamsAPI.reconnectNow()
            self?.pushLights()
        })
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.shutdown()
        })
    }

    func shutdown() {
        menuBarPulseTimer?.invalidate()
        menuBarPulseTimer = nil
        screenLockTokens.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        screenLockTokens.removeAll()
        stopAnimation()
        rainbowUntil = nil
        let all: [LightOutput] = [kuando, blinkStick, matrix, homeAssistant, webhook]
        all.forEach { $0.release() }
        // Network lights: send "off" explicitly so they don't stay red after quitting.
        if settings.homeAssistant.light.enabled {
            homeAssistant.send(color: .off, brightness: 0, force: true)
        }
        teamsAPI.stop()
        axMonitor.stop()
    }

    func requestAccessibility() {
        AccessibilityMonitor.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Start a fresh instance and quit this one. macOS sometimes only honours a new
    /// Accessibility grant after the process restarts.
    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        shutdown()
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, error in
            DispatchQueue.main.async {
                if let error { Log.info("Relaunch failed: \(error.localizedDescription)") }
                NSApp.terminate(nil)
            }
        }
    }

    /// How this binary is signed. Ad-hoc signatures break Accessibility grants on every rebuild.
    let signingSummary: String = {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return "Unknown" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return "Unknown" }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return "Unsigned" }
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & SecCodeSignatureFlags.adhoc.rawValue != 0 {
            return "Ad-hoc (Accessibility grant breaks on every rebuild)"
        }
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
           let subject = SecCertificateCopySubjectSummary(leaf) as String? {
            return subject
        }
        return "Signed"
    }()

    var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func dumpAccessibilityTree() {
        DispatchQueue.global(qos: .userInitiated).async {
            let text = AccessibilityMonitor.dump()
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/TeamsMuteLight", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("teams-ax-dump.txt")
            do {
                try text.write(to: file, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { NSWorkspace.shared.open(file) }
            } catch {
                Log.info("Could not write AX dump: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.info("Launch at login change failed: \(error.localizedDescription)")
            }
            objectWillChange.send()
        }
    }

    // MARK: Presets

    func applyKuandoOnlyPreset() {
        settings.kuando.enabled = true
        settings.kuando.colors = .kuandoOnly
    }

    func applyMuteLightPreset() {
        settings.kuando.colors = .muteLight
    }
}
