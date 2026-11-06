import AppKit
import ApplicationServices
import CoreAudio
import Foundation

/// Fallback detector: reads the Teams meeting mic button through the macOS Accessibility API.
///
/// The button's label describes the action it performs, so:
///   "Unmute mic" / "Unmute (⌘+Shift+M)"  -> you are currently MUTED
///   "Mute mic"   / "Mute (⌘+Shift+M)"    -> you are currently UNMUTED
/// Teams' web UI gives the button DOM id `microphone-button`, which WebKit exposes as AXDOMIdentifier;
/// that is preferred, and label matching is the fallback.
///
/// Requires Accessibility permission (System Settings > Privacy & Security > Accessibility).
/// All AX work runs on a private serial queue; `onChange` is delivered on the main queue.
final class AccessibilityMonitor {
    struct Reading: Equatable {
        var state: MicState
        var detail: String
    }

    static let teamsBundleIDs = ["com.microsoft.teams2", "com.microsoft.teams"]
    static let micButtonDOMIDs: Set<String> = ["microphone-button", "mic-button"]

    var onChange: ((Reading) -> Void)?

    private let queue = DispatchQueue(label: "TeamsMuteLight.accessibility", qos: .utility)
    private var timer: DispatchSourceTimer?

    // Queue-confined state
    private var mutedRegex: NSRegularExpression?
    private var unmutedRegex: NSRegularExpression?
    private var interval: TimeInterval = 0.5
    private var cached: (pid: pid_t, element: AXUIElement)?
    private var lastFullScan = Date.distantPast
    private var lastReading: Reading?
    private let maxNodes = 8000

    // MARK: Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Lifecycle

    /// Returns an error message if a pattern is invalid.
    @discardableResult
    func configure(mutedPattern: String, unmutedPattern: String, interval: TimeInterval) -> String? {
        var problem: String?
        let muted: NSRegularExpression?
        let unmuted: NSRegularExpression?
        do { muted = try NSRegularExpression(pattern: mutedPattern, options: [.caseInsensitive]) }
        catch { muted = nil; problem = "Invalid 'muted' pattern" }
        do { unmuted = try NSRegularExpression(pattern: unmutedPattern, options: [.caseInsensitive]) }
        catch { unmuted = nil; problem = "Invalid 'unmuted' pattern" }
        let iv = max(0.2, min(5, interval))
        queue.async {
            self.mutedRegex = muted
            self.unmutedRegex = unmuted
            let changed = iv != self.interval
            self.interval = iv
            self.cached = nil
            self.lastReading = nil
            if changed, self.timer != nil { self.startOnQueue() }
        }
        if let problem { Log.info(problem) }
        return problem
    }

    func start() { queue.async { if self.timer == nil { self.startOnQueue() } } }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.cached = nil
            self.lastReading = nil
        }
    }

    private func startOnQueue() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        let reading = poll()
        guard reading != lastReading else { return }
        lastReading = reading
        let cb = onChange
        DispatchQueue.main.async { cb?(reading) }
    }

    // MARK: Polling

    private func poll() -> Reading {
        guard AXIsProcessTrusted() else {
            cached = nil
            return Reading(state: .unknown, detail: "Accessibility permission not granted")
        }
        guard let app = Self.runningTeams() else {
            cached = nil
            return Reading(state: .notInMeeting, detail: "Teams not running")
        }
        let pid = app.processIdentifier

        // Fast path: re-read the button we found last time.
        if let c = cached, c.pid == pid, let r = classify(c.element) { return r }
        cached = nil

        // Full tree scans are expensive; throttle them while idle. If any mic is in use, scan more often.
        if let last = lastReading, last.state == .notInMeeting || last.state == .unknown {
            let micHot = Self.anyInputDeviceRunning() ?? true
            let gap: TimeInterval = micHot ? 2 : 10
            if Date().timeIntervalSince(lastFullScan) < gap { return last }
        }
        lastFullScan = Date()

        let appElement = Self.prepareAppElement(pid)
        if preparedPid != pid {
            // First contact with this Teams process: give Chromium time to build the web AX tree.
            preparedPid = pid
            Thread.sleep(forTimeInterval: 1.5)
        }
        if let found = findMicButton(in: appElement) {
            cached = (pid, found.0)
            return found.1
        }
        return Reading(state: .notInMeeting, detail: "No meeting mic button found")
    }

    static func runningTeams() -> NSRunningApplication? {
        for id in teamsBundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { !$0.isTerminated }) {
                return app
            }
        }
        return nil
    }

    /// New Teams renders its UI in a Chromium-based web view, which only builds its accessibility
    /// tree after an assistive client sets AXEnhancedUserInterface (Chromium) or
    /// AXManualAccessibility (Electron). The tree then fills in asynchronously over ~1 s.
    private static func prepareAppElement(_ pid: pid_t) -> AXUIElement {
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.5)
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return el
    }

    private var preparedPid: pid_t?

    // MARK: AX helpers

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        guard let s = attr(el, name) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(200))
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func labels(_ el: AXUIElement) -> [String] {
        [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute].compactMap { string(el, $0) }
    }

    private static func isButtonish(_ role: String) -> Bool {
        role == kAXButtonRole || role == kAXCheckBoxRole || role == "AXToggle" || role == kAXMenuButtonRole
    }

    private func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private func classify(_ el: AXUIElement) -> Reading? {
        for label in Self.labels(el) {
            if matches(mutedRegex, label) { return Reading(state: .muted, detail: "Button: “\(label)”") }
            if matches(unmutedRegex, label) { return Reading(state: .unmuted, detail: "Button: “\(label)”") }
        }
        return nil
    }

    private static func roots(_ app: AXUIElement) -> [AXUIElement] {
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.isEmpty ? children(app) : windows
    }

    /// Breadth-first search; meeting toolbars sit fairly shallow, chat history sits deep.
    private func findMicButton(in app: AXUIElement) -> (AXUIElement, Reading)? {
        var frontier = Self.roots(app)
        var i = 0
        var labelMatch: (AXUIElement, Reading)?
        while i < frontier.count, i < maxNodes {
            let el = frontier[i]
            i += 1
            let role = Self.string(el, kAXRoleAttribute) ?? ""
            if Self.isButtonish(role) {
                let domID = Self.string(el, "AXDOMIdentifier") ?? ""
                if Self.micButtonDOMIDs.contains(domID), let r = classify(el) { return (el, r) }
                if labelMatch == nil, let r = classify(el) { labelMatch = (el, r) }
            }
            if frontier.count < maxNodes { frontier.append(contentsOf: Self.children(el)) }
        }
        return labelMatch
    }

    // MARK: Diagnostics

    /// Lists every button-like element in Teams' windows with its role, DOM id and labels.
    /// Synchronous; call off the main thread in the app.
    static func dump(maxNodes: Int = 20000) -> String {
        guard AXIsProcessTrusted() else {
            return "Accessibility permission not granted for this process.\n(For the CLI, grant it to your terminal app.)"
        }
        guard let app = runningTeams() else { return "Microsoft Teams is not running." }
        let el = prepareAppElement(app.processIdentifier)
        Thread.sleep(forTimeInterval: 2.0) // let the web content's AX tree build
        var out = "Teams: \(app.bundleIdentifier ?? "?") pid \(app.processIdentifier)\n"
        let windows = (attr(el, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for (wi, w) in windows.enumerated() {
            out += "\n=== Window \(wi): \(string(w, kAXTitleAttribute) ?? "(untitled)") ===\n"
            out += "--- Outline (first 250 nodes, depth ≤ 25) ---\n"
            out += outline(w, maxLines: 250, maxDepth: 25)
            out += "--- Buttons ---\n"
            var frontier = [w]
            var i = 0
            var buttons = 0
            while i < frontier.count, i < maxNodes {
                let e = frontier[i]
                i += 1
                let role = string(e, kAXRoleAttribute) ?? ""
                if isButtonish(role) {
                    buttons += 1
                    let id = string(e, "AXDOMIdentifier") ?? "-"
                    let ls = labels(e).map { "“\($0)”" }.joined(separator: " | ")
                    out += "\(role)  id=\(id)  \(ls)\n"
                }
                if frontier.count < maxNodes { frontier.append(contentsOf: children(e)) }
            }
            out += "(\(buttons) buttons, \(i) nodes scanned)\n"
        }
        if windows.isEmpty { out += "No windows exposed via Accessibility.\n" }
        return out
    }

    /// Indented depth-first outline: role/subrole, DOM id, labels, child count.
    private static func outline(_ root: AXUIElement, maxLines: Int, maxDepth: Int) -> String {
        var out = ""
        var lines = 0
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        while lines < maxLines, let item = stack.popLast() {
            let el = item.0
            let depth = item.1
            let role = string(el, kAXRoleAttribute) ?? "?"
            let sub = string(el, kAXSubroleAttribute).map { "/\($0)" } ?? ""
            let id = string(el, "AXDOMIdentifier").map { " id=\($0)" } ?? ""
            let ls = labels(el).map { " “\($0)”" }.joined()
            let kids = children(el)
            out += String(repeating: "  ", count: depth) + "\(role)\(sub)\(id)\(ls) [\(kids.count)]\n"
            lines += 1
            if depth < maxDepth {
                for k in kids.reversed() { stack.append((k, depth + 1)) }
            }
        }
        return out
    }

    // MARK: CoreAudio hint

    /// True if any audio input device is currently being used by any process.
    static func anyInputDeviceRunning() -> Bool? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &runAddr, 0, nil, &runSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}
