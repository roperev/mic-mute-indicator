import Foundation
import IOKit

/// Serial attach/detach notifications, not a periodic device-discovery loop.
final class FirmwareUSBObserver {
    private var notificationPort: IONotificationPortRef?
    private var attached: io_iterator_t = 0
    private var detached: io_iterator_t = 0
    var onChange: (() -> Void)?

    func start() throws {
        guard notificationPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw FirmwareFailure.invalid("Could not observe USB device connections.")
        }
        notificationPort = port
        guard let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() else {
            throw FirmwareFailure.invalid("USB notification run loop is unavailable.")
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
            guard let context else { return }
            let observer = Unmanaged<FirmwareUSBObserver>.fromOpaque(context).takeUnretainedValue()
            observer.onChange?()
        }
        let first = IOServiceAddMatchingNotification(port, kIOFirstMatchNotification,
            IOServiceMatching("IOSerialBSDClient"), callback, context, &attached)
        let last = IOServiceAddMatchingNotification(port, kIOTerminatedNotification,
            IOServiceMatching("IOSerialBSDClient"), callback, context, &detached)
        guard first == KERN_SUCCESS, last == KERN_SUCCESS else {
            throw FirmwareFailure.invalid("Could not register USB connection notifications.")
        }
        while case let service = IOIteratorNext(attached), service != 0 { IOObjectRelease(service) }
        while case let service = IOIteratorNext(detached), service != 0 { IOObjectRelease(service) }
    }

    deinit {
        if attached != 0 { IOObjectRelease(attached) }
        if detached != 0 { IOObjectRelease(detached) }
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
    }
}
