import Foundation
import IOKit.hid

/// Kuando / Plenom Busylight (Alpha, Omega, UC, Alpha 2, Omega 2) over USB HID.
///
/// Protocol (64-byte output report, no report ID):
///   bytes 0..55  : up to 7 "steps" of 8 bytes each
///                  [cmd|target, repeat, red, green, blue, on_time, off_time, audio]
///                  cmd 0x10 = jump-to-step (low nibble = target step), 0x80 = keep-alive (low nibble = timeout s)
///   bytes 56..58 : 0x04 0x04 0x55 (sensitivity / timeout / trigger)
///   bytes 59..61 : 0xFF
///   bytes 62..63 : 16-bit big-endian sum of bytes 0..61
/// The light turns itself off if it hears nothing for a while, so we send a keep-alive every 5 s.
final class KuandoLight: LightOutput {
    let name = "Kuando Busylight"
    let supportsAnimation = true
    var serial = ""

    private var color: RGB = .off
    private var active = false
    private var keepAlive: Timer?
    private var lastError: IOReturn = kIOReturnSuccess
    private var observer: UUID?

    init() {
        observer = HIDDeviceManager.shared.addObserver { [weak self] in self?.resendIfActive() }
    }

    deinit {
        if let observer { HIDDeviceManager.shared.removeObserver(observer) }
        keepAlive?.invalidate()
    }

    var connectedDevice: HIDDeviceInfo? {
        HIDDeviceManager.shared.device(serial: serial, where: { $0.isKuando })?.1
    }

    var statusText: String {
        guard let d = connectedDevice else { return "Not connected" }
        if lastError != kIOReturnSuccess { return "\(d.displayName) — write error \(HIDDeviceManager.hex(lastError))" }
        return "Connected: \(d.displayName)"
    }

    func apply(state: MicState, color: RGB, brightness: Double) {
        self.color = color.scaled(brightness)
        active = true
        send(Self.solidFrame(self.color))
        startKeepAlive()
    }

    func release() {
        guard active else { return }
        active = false
        keepAlive?.invalidate()
        keepAlive = nil
        send(Self.solidFrame(.off))
    }

    private func resendIfActive() {
        guard active else { return }
        send(Self.solidFrame(color))
    }

    private func startKeepAlive() {
        guard keepAlive == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.send(KuandoLight.keepAliveFrame)
        }
        RunLoop.main.add(t, forMode: .common)
        keepAlive = t
    }

    private func send(_ bytes: [UInt8]) {
        guard let device = HIDDeviceManager.shared.device(serial: serial, where: { $0.isKuando })?.0 else { return }
        let r = HIDDeviceManager.shared.setReport(device, type: kIOHIDReportTypeOutput, reportID: 0, bytes: bytes)
        if r != lastError {
            lastError = r
            if r != kIOReturnSuccess { Log.info("Kuando write failed: \(HIDDeviceManager.hex(r))") }
        }
    }

    // MARK: Frames

    static func frame(steps: [[UInt8]]) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 64)
        for (i, step) in steps.prefix(7).enumerated() {
            for (j, v) in step.prefix(8).enumerated() { b[i * 8 + j] = v }
        }
        b[56] = 0x04; b[57] = 0x04; b[58] = 0x55
        b[59] = 0xFF; b[60] = 0xFF; b[61] = 0xFF
        let sum = b[0..<62].reduce(0) { $0 + Int($1) }
        b[62] = UInt8((sum >> 8) & 0xFF)
        b[63] = UInt8(sum & 0xFF)
        return b
    }

    /// Kuando PWM channels run 0...100, not 0...255. Values above 100 just clip to full,
    /// which flattens blends (a rainbow collapses to yellow/cyan/magenta).
    static let maxPWM = 100

    static func pwm(_ v: UInt8) -> UInt8 {
        UInt8((Int(v) * maxPWM + 127) / 255)
    }

    /// Step 0: jump to step 0 (loop forever), solid color, audio byte 0x80 = "update audio: silent".
    static func solidFrame(_ c: RGB) -> [UInt8] {
        frame(steps: [[0x10, 0x00, pwm(c.r), pwm(c.g), pwm(c.b), 0xFF, 0x00, 0x80]])
    }

    static let keepAliveFrame: [UInt8] = frame(steps: [[0x8F, 0, 0, 0, 0, 0, 0, 0]])
}
