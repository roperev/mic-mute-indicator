import Foundation
import IOKit
import IOKit.hid

struct HIDDeviceInfo: Hashable, Identifiable {
    let vendorID: Int
    let productID: Int
    let product: String
    let manufacturer: String
    let serial: String
    let locationID: Int

    var id: String { "\(vendorID):\(productID):\(serial):\(locationID)" }
    var vidpid: String { String(format: "%04X:%04X", vendorID, productID) }
    var displayName: String {
        let name = product.isEmpty ? "HID \(vidpid)" : product
        return serial.isEmpty ? name : "\(name) (\(serial))"
    }

    var isKuando: Bool { vendorID == 0x27BB || (vendorID == 0x04D8 && productID == 0xF848) }
    var isBlinkStick: Bool { vendorID == 0x20A0 && productID == 0x41E5 }
}

/// One IOHIDManager for all supported USB lights. Main run loop only.
final class HIDDeviceManager {
    static let shared = HIDDeviceManager()

    private let manager: IOHIDManager
    private(set) var devices: [IOHIDDevice] = []
    private var observers: [UUID: () -> Void] = [:]

    // Kuando/Plenom (0x27BB, all products) + legacy Busylight (0x04D8:0xF848) + BlinkStick (0x20A0:0x41E5)
    private static let matchers: [(vendor: Int, product: Int?)] = [
        (0x27BB, nil),
        (0x04D8, 0xF848),
        (0x20A0, 0x41E5),
    ]

    private init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matches: [[String: Any]] = Self.matchers.map { m in
            var d: [String: Any] = [kIOHIDVendorIDKey: m.vendor]
            if let p = m.product { d[kIOHIDProductIDKey] = p }
            return d
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDDeviceManager>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDDeviceManager>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            Log.info("IOHIDManagerOpen failed: \(Self.hex(result))")
        }
        if let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            devices = Array(set)
        }
    }

    // MARK: Observers

    @discardableResult
    func addObserver(_ f: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    private func notify() { observers.values.forEach { $0() } }

    private func deviceAdded(_ d: IOHIDDevice) {
        guard !devices.contains(where: { $0 == d }) else { return }
        devices.append(d)
        Log.info("USB light connected: \(info(d).displayName)")
        notify()
    }

    private func deviceRemoved(_ d: IOHIDDevice) {
        let before = devices.count
        devices.removeAll { $0 == d }
        if devices.count != before {
            Log.info("USB light disconnected")
            notify()
        }
    }

    // MARK: Queries

    func info(_ d: IOHIDDevice) -> HIDDeviceInfo {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(d, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func str(_ key: String) -> String { (IOHIDDeviceGetProperty(d, key as CFString) as? String) ?? "" }
        return HIDDeviceInfo(
            vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey),
            product: str(kIOHIDProductKey),
            manufacturer: str(kIOHIDManufacturerKey),
            serial: str(kIOHIDSerialNumberKey),
            locationID: int(kIOHIDLocationIDKey)
        )
    }

    var allInfos: [HIDDeviceInfo] { devices.map(info) }

    /// First device that matches `predicate`, preferring `serial` when non-empty.
    func device(serial: String, where predicate: (HIDDeviceInfo) -> Bool) -> (IOHIDDevice, HIDDeviceInfo)? {
        let candidates = devices.map { ($0, info($0)) }.filter { predicate($0.1) }
        if !serial.isEmpty, let exact = candidates.first(where: { $0.1.serial == serial }) { return exact }
        return candidates.first
    }

    @discardableResult
    func setReport(_ d: IOHIDDevice, type: IOHIDReportType, reportID: Int, bytes: [UInt8]) -> IOReturn {
        bytes.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return IOReturn(bitPattern: 0xE00002C2) } // kIOReturnBadArgument
            return IOHIDDeviceSetReport(d, type, CFIndex(reportID), base, buf.count)
        }
    }

    static func hex(_ r: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: r)) }
}
