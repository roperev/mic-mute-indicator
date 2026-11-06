import Foundation
import IOKit.hid

/// BlinkStick (Nano, Strip, Square, ...) over USB HID feature reports.
///   Report 1: [0x01, R, G, B]                  -> LED 0
///   Report 5: [0x05, channel, index, R, G, B]  -> LED `index`
/// The Nano has 2 LEDs (top and bottom).
final class BlinkStickLight: LightOutput {
    let name = "BlinkStick"
    let supportsAnimation = true
    var serial = ""
    var ledCount = 2

    private var color: RGB = .off
    private var active = false
    private var lastError: IOReturn = kIOReturnSuccess
    private var observer: UUID?

    init() {
        observer = HIDDeviceManager.shared.addObserver { [weak self] in
            guard let self, self.active else { return }
            self.write(self.color)
        }
    }

    deinit {
        if let observer { HIDDeviceManager.shared.removeObserver(observer) }
    }

    var connectedDevice: HIDDeviceInfo? {
        HIDDeviceManager.shared.device(serial: serial, where: { $0.isBlinkStick })?.1
    }

    var statusText: String {
        guard let d = connectedDevice else { return "Not connected" }
        if lastError != kIOReturnSuccess { return "\(d.displayName) — write error \(HIDDeviceManager.hex(lastError))" }
        return "Connected: \(d.displayName)"
    }

    func apply(state: MicState, color: RGB, brightness: Double) {
        self.color = color.scaled(brightness)
        active = true
        write(self.color)
    }

    func release() {
        guard active else { return }
        active = false
        write(.off)
    }

    private func write(_ c: RGB) {
        guard let device = HIDDeviceManager.shared.device(serial: serial, where: { $0.isBlinkStick })?.0 else { return }
        let m = HIDDeviceManager.shared
        var r = m.setReport(device, type: kIOHIDReportTypeFeature, reportID: 1, bytes: [1, c.r, c.g, c.b])
        let count = max(1, min(64, ledCount))
        if count > 1 {
            for i in 1..<count {
                let ri = m.setReport(device, type: kIOHIDReportTypeFeature, reportID: 5, bytes: [5, 0, UInt8(i), c.r, c.g, c.b])
                if ri != kIOReturnSuccess { r = ri }
            }
        }
        if r != lastError {
            lastError = r
            if r != kIOReturnSuccess { Log.info("BlinkStick write failed: \(HIDDeviceManager.hex(r))") }
        }
    }
}
