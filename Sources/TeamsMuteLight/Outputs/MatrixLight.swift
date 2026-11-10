import Darwin
import Foundation
import IOKit

struct MatrixDeviceInfo: Equatable, Identifiable {
    let path: String
    let serial: String
    var id: String { path }
    var displayName: String { serial.isEmpty ? path : "\(serial) (\(path))" }

    static func connected() -> [MatrixDeviceInfo] {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator)
        guard result == KERN_SUCCESS else {
            Log.info("Matrix serial discovery failed: \(result)")
            return []
        }
        defer { IOObjectRelease(iterator) }
        var devices: [MatrixDeviceInfo] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                )
            }
            guard (property("idVendor") as? NSNumber)?.intValue == 0x303A,
                  let path = property("IOCalloutDevice") as? String else { continue }
            devices.append(MatrixDeviceInfo(path: path, serial: property("USB Serial Number") as? String ?? ""))
        }
        return devices.sorted { $0.path < $1.path }
    }
}

/// Serial I/O runs on a private queue; only UI snapshots and configuration live on the main thread.
final class MatrixLight: LightOutput {
    let name = "Waveshare Matrix"
    let supportsAnimation = true
    var serial = ""
    var icons = MatrixIcons()
    var rotation = 0
    var mirrored = false
    var fullColor = true
    var colorStyles: MatrixColorStyles?
    var brightnessLevels = MatrixBrightnessLevels()
    private var animationState: MicState?
    private var animationIcon: MatrixIcon?
    private var iconAnimationStart = ProcessInfo.processInfo.systemUptime
    var onChange: (() -> Void)?
    private(set) var statusText = "Disabled"
    private(set) var devices: [MatrixDeviceInfo] = []
    private(set) var connectedDevice: MatrixDeviceInfo?
    private(set) var acknowledgedFrames = 0
    private(set) var supportsPresets = false

    private enum Payload: Equatable {
        case frame(MatrixFrame)
        case preset(MatrixPreset)

        func command(sequence: UInt32, now: TimeInterval) -> Data {
            switch self {
            case .frame(let frame): return frame.command(sequence: sequence)
            case .preset(let preset): return preset.command(sequence: sequence, now: now)
            }
        }
    }

    private struct Wanted: Equatable {
        let serial: String
        let payload: Payload
    }
    private struct Pending {
        let sequence: UInt32
        let payload: Payload
        let started: TimeInterval
    }

    private let queue = DispatchQueue(label: "TeamsMuteLight.matrix")
    private let discover: () -> [MatrixDeviceInfo]
    private var timer: DispatchSourceTimer?
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var wanted: Wanted?
    private var descriptor: Int32 = -1
    private var openedDevice: MatrixDeviceInfo?
    private var identified = false
    private var candidates: [MatrixDeviceInfo] = []
    private var input = Data()
    private var outgoing = Data()
    private var pending: Pending?
    private var lastAcknowledged: Payload?
    private var presetFirmware = false
    private var sequence: UInt32 = 0
    private var openedAt: TimeInterval = 0
    private var lastHello: TimeInterval = 0
    private var lastSend: TimeInterval = 0
    private var lastDiscovery: TimeInterval = -.infinity
    private var retryAt: TimeInterval = 0
    private var publishedStatus = "Disabled"
    private var publishedDevice: MatrixDeviceInfo?
    private var frameCount = 0
    private var transportTicks = 0
    private var discoveries = 0
    private var transmittedBytes = 0

    struct Measurement: Codable {
        let transportTicks: Int
        let discoveries: Int
        let acknowledgedFrames: Int
        let transmittedBytes: Int
    }

    func measurement() -> Measurement {
        queue.sync {
            Measurement(transportTicks: transportTicks, discoveries: discoveries,
                acknowledgedFrames: frameCount, transmittedBytes: transmittedBytes)
        }
    }

    init(discover: @escaping () -> [MatrixDeviceInfo] = MatrixDeviceInfo.connected) {
        self.discover = discover
    }

    private func startMaintenance() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.transportTicks += 1
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    deinit {
        timer?.cancel()
        writer?.cancel()
        reader?.cancel()
    }

    func apply(state: MicState, color: RGB, brightness: Double) {
        guard brightness.isFinite, brightnessLevels[state].isFinite else {
            release()
            statusText = "Error: invalid matrix brightness"
            Log.info(statusText)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if animationState != state || animationIcon != icons[state] {
            animationState = state
            animationIcon = icons[state]
            iconAnimationStart = now
        }
        enqueue(.frame(MatrixFrame.status(state: state, color: color, brightness: brightness, icons: icons,
            rotation: rotation, mirrored: mirrored, fullColor: fullColor, styles: colorStyles,
            levels: brightnessLevels, animationTime: now - iconAnimationStart)))
    }

    func applyStatus(state: MicState, color: RGB, brightness: Double, effect: StateEffect,
                     phaseStart: Date, now: Date) {
        guard supportsPresets else {
            apply(state: state, color: color.scaled(Effects.level(effect.effect,
                rateHz: effect.rateHz, t: now.timeIntervalSince(phaseStart))), brightness: brightness)
            return
        }
        guard brightness.isFinite, brightnessLevels[state].isFinite, effect.rateHz.isFinite else {
            release()
            statusText = "Error: invalid matrix preset"
            Log.info(statusText)
            return
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        if animationState != state || animationIcon != icons[state] {
            animationState = state
            animationIcon = icons[state]
            iconAnimationStart = uptime
        }
        let unavailable = state == .unknown
        let master = min(MatrixFrame.maxBrightness, Int((LightBrightness.clamped(brightness,
            maximum: MatrixFrame.maxLevel) * 255).rounded()))
        let relative = unavailable ? 1 : max(0, min(1, brightnessLevels[state]))
        enqueue(.preset(MatrixPreset(icon: unavailable ? .warning : icons[state],
            style: unavailable ? .artwork : (colorStyles?[state] ?? (fullColor ? .artwork : .solid)),
            color: unavailable ? .green : color, brightness: master,
            flags: max(0, min(3, rotation)) + (mirrored ? 4 : 0),
            relative: Int((relative * 10000).rounded()),
            effect: unavailable ? .solid : effect.effect,
            rateMilliHz: Int((max(0.1, min(10, effect.rateHz)) * 1000).rounded()),
            effectStart: phaseStart.timeIntervalSinceReferenceDate,
            iconStart: iconAnimationStart)))
    }

    func applyRainbow(t: TimeInterval, duration: TimeInterval, sweeps: Int, brightness: Double) {
        guard brightness.isFinite else {
            release()
            statusText = "Error: invalid matrix brightness"
            Log.info(statusText)
            return
        }
        enqueue(.frame(MatrixFrame(pixels: Effects.matrixRainbow(t: t, duration: duration, sweeps: sweeps),
            brightness: brightness, rotation: rotation, mirrored: mirrored)))
    }

    private func enqueue(_ payload: Payload) {
        let request = Wanted(serial: serial, payload: payload)
        queue.async { [weak self] in
            guard let self else { return }
            if self.wanted?.serial != request.serial {
                self.closePort(sendOff: true)
                self.retryAt = 0
            }
            self.wanted = request
            self.startMaintenance()
            self.tick()
        }
    }

    func release() {
        animationState = nil
        animationIcon = nil
        queue.sync {
            wanted = nil
            timer?.cancel()
            timer = nil
            closePort(sendOff: true)
            publish("Disabled", device: nil)
        }
    }

    private func publish(_ status: String, device: MatrixDeviceInfo?) {
        guard status != publishedStatus || device != publishedDevice else { return }
        publishedStatus = status
        publishedDevice = device
        let supports = presetFirmware
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusText = status
            self.connectedDevice = device
            self.supportsPresets = supports
            self.onChange?()
        }
    }

    private func fail(_ message: String) {
        let status = "Error: \(message)"
        if publishedStatus != status { Log.info("Matrix: \(message)") }
        closePort(sendOff: true)
        retryAt = ProcessInfo.processInfo.systemUptime + 1
        publish(status, device: nil)
    }

    private func closePort(sendOff: Bool) {
        if descriptor >= 0 {
            if sendOff && identified {
                sequence &+= 1
                // A leading newline also terminates any partially written DRAW.
                let off = Data("\nOFF \(sequence)\n".utf8)
                let written = off.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress, bytes.count)
                }
                if written != off.count {
                    Log.info("Matrix: could not send complete OFF; firmware will clear within 3 seconds")
                }
            }
            writer?.cancel()
            writer = nil
            reader?.cancel()
            reader = nil
        }
        descriptor = -1
        openedDevice = nil
        identified = false
        presetFirmware = false
        input.removeAll()
        outgoing.removeAll()
        pending = nil
        lastAcknowledged = nil
    }

    private func openPort(_ device: MatrixDeviceInfo, now: TimeInterval) {
        let fd = Darwin.open(device.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { fail("Open \(device.path): \(String(cString: strerror(errno)))"); return }
        descriptor = fd
        let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        reader.setEventHandler { [weak self] in
            guard let self else { return }
            if self.reader?.data == 0 { self.fail("USB device disconnected") }
            else { self.tick() }
        }
        reader.setCancelHandler { Darwin.close(fd) }
        self.reader = reader
        reader.resume()
        var options = termios()
        guard ioctl(fd, TIOCEXCL) == 0, tcgetattr(fd, &options) == 0 else {
            fail("Configure serial port: \(String(cString: strerror(errno)))"); return
        }
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(HUPCL)
        guard cfsetspeed(&options, speed_t(B115200)) == 0,
              tcsetattr(fd, TCSANOW, &options) == 0,
              tcflush(fd, TCIOFLUSH) == 0 else {
            fail("Set serial options: \(String(cString: strerror(errno)))"); return
        }
        var modemBits = Int32(TIOCM_DTR)
        guard ioctl(fd, TIOCMBIS, &modemBits) == 0 else {
            fail("Assert USB serial DTR: \(String(cString: strerror(errno)))"); return
        }
        openedDevice = device
        openedAt = now
        lastHello = -.infinity
        publish("Checking firmware on \(device.path)", device: nil)
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        guard let wanted else { return }
        if descriptor < 0 && now - lastDiscovery >= 1 {
            discoveries += 1
            lastDiscovery = now
            let found = discover()
            if found != candidates {
                candidates = found
                DispatchQueue.main.async { [weak self] in
                    self?.devices = found
                    self?.onChange?()
                }
            }
        }
        if descriptor < 0 {
            guard now >= retryAt else { return }
            let candidate = wanted.serial.isEmpty ? candidates.first
                : candidates.first { $0.serial == wanted.serial }
            guard let candidate else {
                publish(wanted.serial.isEmpty ? "No ESP32 USB device found" : "Selected matrix not connected", device: nil)
                return
            }
            openPort(candidate, now: now)
        }
        guard descriptor >= 0, readReplies() else { return }
        if !identified {
            guard now - openedAt < 3 else {
                fail("No MicMatrix v3/v4/IMU response; flash the board or select its serial number")
                return
            }
            if outgoing.isEmpty && now - lastHello >= 0.5 {
                // Recover framing if a previous USB close truncated its final command.
                outgoing = Data("\nHELLO\n".utf8)
                lastHello = now
            }
        } else if let pending {
            if now - pending.started >= 1 {
                fail("No acknowledgement for frame \(pending.sequence)")
                return
            }
        } else if outgoing.isEmpty && (lastAcknowledged != wanted.payload || now - lastSend >= 0.9) {
            sequence &+= 1
            pending = Pending(sequence: sequence, payload: wanted.payload, started: now)
            if presetFirmware && lastAcknowledged == wanted.payload {
                outgoing = Data("KEEP \(sequence)\n".utf8)
            } else {
                outgoing = wanted.payload.command(sequence: sequence, now: now)
            }
            lastSend = now
        }
        writeOutgoing()
    }

    private func writeOutgoing() {
        guard !outgoing.isEmpty else { return }
        let count = outgoing.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        if count > 0 {
            transmittedBytes += count
            outgoing.removeFirst(count)
        }
        else if count < 0 && errno != EAGAIN && errno != EINTR {
            fail("Serial write: \(String(cString: strerror(errno)))")
        }
        if !outgoing.isEmpty && descriptor >= 0 && writer == nil {
            let writer = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
            writer.setEventHandler { [weak self] in self?.writeOutgoing() }
            self.writer = writer
            writer.resume()
        } else if outgoing.isEmpty {
            writer?.cancel()
            writer = nil
        }
    }

    private func readReplies() -> Bool {
        var bytes = [UInt8](repeating: 0, count: 256)
        for _ in 0..<4 {
            let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { return true }
                fail("Serial read: \(String(cString: strerror(errno)))")
                return false
            }
            if count == 0 { return true }
            input.append(contentsOf: bytes.prefix(count))
            while let newline = input.firstIndex(of: 10) {
                let data = input.prefix(upTo: newline)
                input.removeSubrange(...newline)
                guard data.count <= 512 else { fail("Firmware reply too long"); return false }
                guard let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      let reply = MatrixReply(line: line) else { continue } // Ignore boot diagnostics.
                switch reply {
                case .hello, .presets:
                    guard !identified else { continue }
                    identified = true
                    presetFirmware = reply == .presets
                    let supports = presetFirmware
                    DispatchQueue.main.async { [weak self] in
                        self?.supportsPresets = supports
                        self?.onChange?()
                    }
                    outgoing.removeAll()
                    publish("Firmware connected; awaiting first frame", device: openedDevice)
                case .acknowledged(let id):
                    guard let pending, pending.sequence == id else { continue }
                    lastAcknowledged = pending.payload
                    self.pending = nil
                    frameCount += 1
                    let count = frameCount
                    DispatchQueue.main.async { [weak self] in self?.acknowledgedFrames = count }
                    publish("OK (USB, auto-orient, brightness capped at 10%)", device: openedDevice)
                case .timeout:
                    lastAcknowledged = nil
                    publish("Display timed out; resending state", device: openedDevice)
                case .error(let error):
                    if !identified {
                        Log.info("Matrix: draining pre-handshake firmware error: \(error)")
                        continue
                    }
                    fail("Firmware rejected command: \(error)")
                    return false
                }
            }
            if input.count > 512 { fail("Firmware reply too long"); return false }
        }
        return true
    }
}
