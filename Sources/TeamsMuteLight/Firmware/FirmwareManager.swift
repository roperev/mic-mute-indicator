import AppKit
import Combine
import Foundation
import IOKit.pwr_mgt

enum FirmwareAppearance {
    case neutral, ready, information, warning
}

struct FirmwareDeviceState {
    var mac: String?
    var message = "Possibly stock — firmware not recognized"
    var appearance = FirmwareAppearance.information
}

final class FirmwareManager: ObservableObject, FirmwareTerminationState {
    @Published private(set) var devices: [MatrixDeviceInfo] = []
    @Published var selectedPath = "" {
        didSet { if oldValue != selectedPath { reloadBackups() } }
    }
    @Published private(set) var states: [String: FirmwareDeviceState] = [:]
    @Published private(set) var busy = false
    @Published private(set) var protectedOperation = false
    @Published private(set) var message = "Connect a Waveshare ESP32-S3-Matrix."
    @Published private(set) var error: String?
    @Published private(set) var progress: Double?
    @Published private(set) var backups: [(FirmwareBackup, URL)] = []
    @Published private(set) var bundledBuild = "Not available"
    @Published private(set) var recoveryMessage: String?
    @Published var showingProgress = false
    var suspendOutput: ((@escaping () -> Void) -> Void)?
    var resumeOutput: (() -> Void)?
    var didInstall: ((MatrixDeviceInfo, Bool) -> Void)?
    var didRestore: ((MatrixDeviceInfo) -> Void)?

    private let observer = FirmwareUSBObserver()
    private var refreshWork: DispatchWorkItem?
    private var session: FirmwareProcess?
    private var probe: MatrixLight?
    private var assertion: IOPMAssertionID = 0
    private var activity: NSObjectProtocol?
    private var operation = ""
    private var target: MatrixDeviceInfo?
    private var helperComplete = false
    private var operationFailed = false
    private var cancelled = false
    private var useAfterInstall = true
    private var activePath: String?
    private var operationMAC: String?
    private var checkWork: DispatchWorkItem?

    var selectedDevice: MatrixDeviceInfo? { devices.first { $0.path == selectedPath } }
    var selectedState: FirmwareDeviceState { states[selectedPath] ?? FirmwareDeviceState() }
    var original: (FirmwareBackup, URL)? { backups.first { $0.0.role == "original" } }

    func start() {
        do {
            let (manifest, _, _) = try FirmwareManifest.load()
            bundledBuild = String(manifest.buildID.prefix(12))
        } catch { self.error = "Firmware resources unavailable: \(error.localizedDescription)" }
        observer.onChange = { [weak self] in self?.scheduleRefresh() }
        do { try observer.start() }
        catch { report(error.localizedDescription) }
        readRecovery()
        refresh()
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func refresh() {
        let found = MatrixDeviceInfo.connected()
        let previous = Set(devices.map(\.path))
        devices = found
        guard !busy else { return }
        if let activePath, !found.contains(where: { $0.path == activePath }) {
            self.activePath = nil
        }
        for path in states.keys where !found.contains(where: { $0.path == path }) {
            states.removeValue(forKey: path)
        }
        if !found.contains(where: { $0.path == selectedPath }) {
            selectedPath = found.first?.path ?? ""
        }
        for device in found where states[device.path] == nil {
            var rememberedMAC: String?
            if let mac = FirmwareFiles.normalizedMAC(device.serial) {
                do {
                    if !(try FirmwareBackupStore.backups(for: mac)).isEmpty { rememberedMAC = mac }
                } catch { report("Could not validate this board's retained backups: \(error.localizedDescription)") }
            }
            // USB serial is a lookup hint only. The helper rechecks the actual MAC before writes.
            states[device.path] = FirmwareDeviceState(mac: rememberedMAC, message: "Checking firmware…")
        }
        if let device = selectedDevice, activePath != device.path,
           !previous.contains(device.path) || selectedState.message == "Checking firmware…" {
            probeDevice(device)
        }
    }

    func observe(_ matrix: MatrixLight) {
        guard !busy else { return }
        guard let device = matrix.connectedDevice else {
            if let activePath, matrix.statusText.hasPrefix("Error:") {
                let firmwareFault = matrix.statusText.contains("Unsupported MicMatrix") || matrix.statusText.contains("imu-")
                states[activePath]?.message = matrix.statusText +
                    (firmwareFault ? ". Refresh or inspect the board to retry." : ". Reconnecting automatically.")
                states[activePath]?.appearance = .warning
                if firmwareFault {
                    self.activePath = nil
                    matrix.release()
                }
            }
            return
        }
        activePath = device.path
        let knownBuild = states[device.path]?.message
        states[device.path] = FirmwareDeviceState(mac: states[device.path]?.mac,
            message: matrix.statusText.hasPrefix("OK")
                ? (knownBuild?.contains("bundled build") == true ? knownBuild! :
                    "MicMatrix ready · protocol \(matrix.supportsPresets ? 4 : 3) · build not reported")
                : "MicMatrix recognized · checking display",
            appearance: .ready)
    }

    func suppressesOutput(serial: String) -> Bool {
        if busy { return true }
        let candidate = serial.isEmpty ? devices.first : devices.first { $0.serial == serial }
        guard let candidate, let state = states[candidate.path] else { return false }
        // A known healthy board retains the transport's normal retry behavior for transient I/O errors.
        if candidate.path == activePath, state.message.hasPrefix("Error:") { return false }
        return state.appearance != .ready
    }

    func checkConnection() {
        guard !busy, let device = selectedDevice else { return }
        probeDevice(device)
    }

    static func runFirmwareCLI(_ arguments: [String]) throws {
        guard arguments.count >= 2, ["status", "inspect", "install", "restore", "import"].contains(arguments[0]) else {
            throw FirmwareFailure.invalid("Usage: --cli firmware status|inspect|install|restore|import <exact-port> [--confirm-board] [--confirm-erase] [--backup-path <original.bin>]")
        }
        let manager = FirmwareManager()
        let quitGuard = FirmwareApplicationDelegate()
        quitGuard.blockedQuitNotification = {}
        FirmwareApplicationDelegate.manager = manager
        defer { FirmwareApplicationDelegate.manager = nil }
        var checkedProtectedQuit = false
        manager.start()
        let warmup = Date().addingTimeInterval(6)
        while manager.busy && Date() < warmup {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        manager.selectedPath = arguments[1]
        guard manager.selectedDevice != nil, !manager.busy else {
            throw FirmwareFailure.invalid("The exact selected USB device is not available.")
        }
        if arguments[0] == "status" {
            print("Device: \(manager.selectedPath)")
            print("Firmware: \(manager.selectedState.message)")
            return
        }
        // Even diagnostic commands use the same inspection, identity and transaction service as Settings.
        manager.inspect()
        func awaitOperation() throws {
            var last = ""
            while manager.busy {
                if arguments.contains("--test-quit-guard"), manager.protectedOperation,
                   !checkedProtectedQuit {
                    precondition(quitGuard.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
                    precondition(manager.busy && manager.protectedOperation)
                    checkedProtectedQuit = true
                    print("Verified: native Quit rejected during this protected firmware transaction.")
                }
                if last != manager.message {
                    print(manager.message)
                    last = manager.message
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            }
            if let error = manager.error { throw FirmwareFailure.invalid(error) }
        }
        try awaitOperation()
        if let index = arguments.firstIndex(of: "--expected-mac") {
            guard index + 1 < arguments.count,
                  let expected = FirmwareFiles.normalizedMAC(arguments[index + 1]),
                  manager.selectedState.mac == expected else {
                throw FirmwareFailure.invalid("The inspected board is not the expected chip. No destructive operation was started.")
            }
        }
        if arguments[0] == "import" {
            guard arguments.contains("--confirm-board"),
                  let index = arguments.firstIndex(of: "--backup-path"), index + 1 < arguments.count else {
                throw FirmwareFailure.invalid("Import requires --confirm-board and --backup-path for this exact device's original image.")
            }
            manager.importOriginal(URL(fileURLWithPath: arguments[index + 1]), factory: true,
                confirmedMAC: manager.selectedState.mac ?? "")
            if let error = manager.error { throw FirmwareFailure.invalid(error) }
        } else if arguments[0] != "inspect" {
            guard arguments.contains("--confirm-board"), arguments.contains("--confirm-erase") else {
                throw FirmwareFailure.invalid("This destructive diagnostic requires --confirm-board --confirm-erase. A verified backup is mandatory.")
            }
            if arguments[0] == "install" {
                manager.install(backup: true, skipConfirmed: false, use: false,
                    confirmedMAC: manager.selectedState.mac ?? "")
            } else {
                manager.restore(confirmedMAC: manager.selectedState.mac ?? "")
            }
            try awaitOperation()
            if arguments.contains("--test-quit-guard") {
                guard checkedProtectedQuit else {
                    throw FirmwareFailure.invalid("The destructive phase was not observed by the quit-guard test.")
                }
                precondition(quitGuard.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            }
        }
        print(manager.message)
        print("Identity: \(manager.selectedState.mac ?? "not reported")")
        print("Firmware: \(manager.selectedState.message)")
        for (backup, _) in manager.backups {
            print("Verified \(backup.role) backup: \(backup.imagePath)")
        }
    }

    private func probeDevice(_ device: MatrixDeviceInfo) {
        guard !busy else { return }
        busy = true
        message = "Checking firmware without flashing…"
        let begin = { [weak self] in
            guard let self else { return }
            let matrix = MatrixLight(discover: { [device] })
            self.probe = matrix
            matrix.serial = device.serial
            matrix.onChange = { [weak self, weak matrix] in
                guard let self, let matrix, self.probe === matrix else { return }
                if matrix.statusText.hasPrefix("OK") {
                    self.finishProbe(device, recognized: true, presets: matrix.supportsPresets)
                } else if matrix.statusText.contains("Unsupported MicMatrix") ||
                    matrix.statusText.contains("imu-") {
                    self.finishProbe(device, recognized: false, presets: false, warning: matrix.statusText)
                }
            }
            matrix.apply(state: .unmuted, color: .off, brightness: 0)
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.probe != nil else { return }
                self.finishProbe(device, recognized: false, presets: false)
            }
            self.checkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
        }
        if let suspendOutput { suspendOutput(begin) } else { begin() }
    }

    private func finishProbe(_ device: MatrixDeviceInfo, recognized: Bool, presets: Bool, warning: String? = nil) {
        checkWork?.cancel()
        let matrix = probe
        probe = nil
        states[device.path] = FirmwareDeviceState(mac: states[device.path]?.mac,
            message: warning ?? (recognized ? "MicMatrix ready · protocol \(presets ? 4 : 3) · build not reported"
                : "Possibly stock — firmware not recognized. Inspect to identify the chip and firmware."),
            appearance: warning != nil ? .warning : recognized ? .ready : .information)
        let finish = { [weak self] in
            guard let self else { return }
            self.busy = false
            self.message = self.states[device.path]?.message ?? "Firmware check ended."
            self.reloadBackups()
            self.resumeOutput?()
        }
        if let matrix { matrix.releaseForFirmware(completion: finish) } else { finish() }
    }

    func inspect() {
        launch(operation: "inspect", backup: true, skipConfirmed: false, use: false)
    }

    func install(backup: Bool, skipConfirmed: Bool, use: Bool, confirmedMAC: String) {
        guard selectedState.mac == confirmedMAC else {
            report("The selected board changed after confirmation. Inspect and confirm the intended device again.")
            return
        }
        guard backup || skipConfirmed else {
            report("Installing without a backup requires the second destructive confirmation.")
            return
        }
        launch(operation: "install", backup: backup, skipConfirmed: skipConfirmed, use: use)
    }

    func restore(confirmedMAC: String) {
        guard selectedState.mac == confirmedMAC else {
            report("The selected board changed after confirmation. Restore was not started.")
            return
        }
        guard let original else { report("No verified original backup is available for this board."); return }
        launch(operation: "restore", backup: true, skipConfirmed: false, use: false,
            restoring: original)
    }

    private func launch(operation: String, backup: Bool, skipConfirmed: Bool, use: Bool,
                        restoring: (FirmwareBackup, URL)? = nil) {
        guard !busy, let device = selectedDevice else { return }
        do {
            let (manifest, image, helper) = try FirmwareManifest.load()
            bundledBuild = String(manifest.buildID.prefix(12))
            let mac = selectedState.mac
            guard operation == "inspect" || mac != nil else {
                throw FirmwareFailure.invalid("Inspect this device first to verify its chip identity.")
            }
            if let restoring, let mac { try restoring.0.validate(for: mac) }
            try FirmwareBackupStore.prepare(FirmwareBackupStore.root)
            let directory = FirmwareBackupStore.root.appendingPathComponent(
                mac?.replacingOccurrences(of: ":", with: "") ?? "Inspection")
            try FirmwareBackupStore.prepare(directory)
            let request = FirmwareRequest(operation: operation, port: device.path, expectedMAC: mac,
                imagePath: restoring?.0.imagePath ?? image.path,
                imageSHA256: restoring?.0.sha256 ?? manifest.sha256,
                backupDirectory: directory.path, backup: backup, skipBackupConfirmed: skipConfirmed,
                restoreMetadataPath: restoring?.1.path)
            self.operation = operation
            operationMAC = mac
            target = device
            useAfterInstall = use
            busy = true
            error = nil
            progress = nil
            cancelled = false
            helperComplete = false
            operationFailed = false
            showingProgress = true
            message = "Preparing \(operation). The device may reset into its bootloader."
            let begin = { [weak self] in
                guard let self else { return }
                let session = FirmwareProcess()
                self.session = session
                session.onEvent = { [weak self] in self?.receive($0) }
                session.onExit = { [weak self] status, failure in self?.exited(status, failure: failure) }
                do { try session.start(helper: helper, request: request) }
                catch { self.exited(-1, failure: error.localizedDescription) }
            }
            if let suspendOutput { suspendOutput(begin) } else { begin() }
        } catch { report(error.localizedDescription) }
    }

    private func receive(_ event: FirmwareEvent) {
        if let value = event.progress, value.isFinite { progress = max(0, min(1, value)) }
        if let text = event.message { message = text }
        switch event.type {
        case "device":
            guard let target, let mac = event.mac.flatMap(FirmwareFiles.normalizedMAC),
                  event.chip == "esp32s3", event.flashSize == 4_194_304, event.secured == false else {
                report("Unsupported, protected or unidentified device. No firmware will be written.")
                operationFailed = true
                cancel()
                return
            }
            let firmware = event.firmware ?? "unrecognized"
            let stock = firmware.lowercased().contains("stock")
            let custom = firmware.lowercased().contains("micmatrix")
            states[target.path] = FirmwareDeviceState(mac: mac,
                message: custom ? "MicMatrix identified · checking readiness" : stock ? "Stock firmware recognized"
                    : firmware == "unrecognized" ? "Possibly stock — firmware not recognized"
                    : "Alternate firmware: \(firmware)",
                appearance: custom || stock || firmware == "unrecognized" ? .information : .warning)
            operationMAC = mac
        case "backup":
            reloadBackups()
        case "readyToWrite":
            guard !cancelled, !operationFailed, error == nil, let mac = operationMAC else {
                cancel()
                return
            }
            do {
                try protect()
                try session?.send(command: "authorizeWrite", mac: mac)
            } catch {
                report("Could not establish flashing protection: \(error.localizedDescription)")
                operationFailed = true
                do { try session?.send(command: "cancel", mac: nil) }
                catch { report("Could not stop the pre-write helper: \(error.localizedDescription)") }
            }
        case "complete":
            helperComplete = true
        case "error":
            operationFailed = true
            report(event.message ?? "The firmware operation failed.")
        case "progress":
            break
        default:
            operationFailed = true
            report("Unrecognized firmware-helper event. Installation will not be authorized.")
            if !protectedOperation { cancel() }
        }
    }

    private func protect() throws {
        guard !protectedOperation else { return }
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Verifying matrix firmware" as CFString, &assertion)
        guard result == kIOReturnSuccess else {
            throw FirmwareFailure.invalid("macOS could not prevent idle sleep.")
        }
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Installing and verifying matrix firmware")
        protectedOperation = true
    }

    private func unprotect() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        protectedOperation = false
    }

    func cancel() {
        guard busy, !protectedOperation, !cancelled else { return }
        cancelled = true
        message = "Cancelling safely before erasure; waiting for the helper to release the board…"
        do { try session?.send(command: "cancel", mac: nil) }
        catch { report("Could not request cancellation: \(error.localizedDescription)") }
    }

    private func exited(_ status: Int32, failure: String?) {
        session = nil
        reloadBackups()
        if status != 0 || !helperComplete || operationFailed || failure != nil {
            if let failure { report(failure) }
            else if error == nil { report(cancelled ? "Operation cancelled before erasure."
                : "Firmware operation did not complete (exit \(status)). Keep your backup and retry in BOOT/RESET mode.") }
            cleanup()
            return
        }
        if let target, operation == "install" ||
            (operation == "inspect" && states[target.path]?.message.hasPrefix("MicMatrix identified") == true) {
            message = operation == "install" ? "Flash verified. Checking MicMatrix and its accelerometer…"
                : "Identity inspected. Checking MicMatrix and its accelerometer…"
            postInstallCheck(target)
        } else {
            if operation == "restore", let target {
                states[target.path]?.message = "Original firmware restored and verified."
                states[target.path]?.appearance = .information
                didRestore?(target)
                message = "Original firmware restored and verified. Matrix output is disabled."
            } else {
                message = "Inspection complete. Chip identity verified; no flash contents changed."
            }
            cleanup()
        }
    }

    private func postInstallCheck(_ device: MatrixDeviceInfo) {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        func check() {
            let found = MatrixDeviceInfo.connected()
            let mac = operationMAC
            let candidate = found.first {
                if let mac { return FirmwareFiles.normalizedMAC($0.serial) == mac }
                return false
            }
            guard let candidate else {
                if ProcessInfo.processInfo.systemUptime < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: check)
                } else {
                    report("The same board did not reconnect after reset. Press RESET and check its USB cable. Retain all verified backups.")
                    cleanup()
                }
                return
            }
            let matrix = MatrixLight(discover: { [candidate] })
            probe = matrix
            matrix.serial = candidate.serial
            matrix.onChange = { [weak self, weak matrix] in
                guard let self, let matrix, self.probe === matrix,
                      matrix.statusText.hasPrefix("OK"),
                      self.operation != "install" || matrix.supportsPresets else { return }
                self.checkWork?.cancel()
                self.probe = nil
                let protocolVersion = matrix.supportsPresets ? 4 : 3
                matrix.releaseForFirmware {
                    let installed = self.operation == "install"
                    self.states[candidate.path] = FirmwareDeviceState(mac: mac,
                        message: installed ? "MicMatrix ready · protocol 4 · bundled build \(self.bundledBuild)"
                            : "MicMatrix ready · protocol \(protocolVersion) · build not reported",
                        appearance: .ready)
                    self.selectedPath = candidate.path
                    self.message = installed ? "MicMatrix installed, flash verified and accelerometer ready."
                        : "MicMatrix identity and accelerometer checked; no flash contents changed."
                    if installed { self.didInstall?(candidate, self.useAfterInstall) }
                    self.cleanup()
                }
            }
            matrix.apply(state: .unmuted, color: .off, brightness: 0)
            let work = DispatchWorkItem { [weak self, weak matrix] in
                guard let self, let matrix, self.probe === matrix else { return }
                self.probe = nil
                matrix.releaseForFirmware {
                    self.report("MicMatrix/IMU did not respond after reset. Keep the backup; retry RESET or restore original firmware.")
                    self.cleanup()
                }
            }
            checkWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: check)
    }

    private func cleanup() {
        if let error, let target {
            activePath = nil
            states[target.path] = FirmwareDeviceState(mac: operationMAC,
                message: error, appearance: .warning)
        }
        unprotect()
        busy = false
        progress = nil
        readRecovery()
        refresh()
        resumeOutput?()
    }

    func reloadBackups() {
        guard let mac = states[selectedPath]?.mac else { backups = []; return }
        do { backups = try FirmwareBackupStore.backups(for: mac) }
        catch { report("Backup validation failed: \(error.localizedDescription)"); backups = [] }
    }

    func importOriginal(_ url: URL, factory: Bool, confirmedMAC: String) {
        guard !busy, let mac = selectedState.mac, mac == confirmedMAC else {
            report("The selected board changed. Import was not started.")
            return
        }
        do {
            _ = try FirmwareBackupStore.importBackup(url, mac: mac, factory: factory)
            reloadBackups()
            message = "Imported backup validated. Device provenance was confirmed by you."
        } catch { report(error.localizedDescription) }
    }

    private func readRecovery() {
        recoveryMessage = nil
        guard let enumerator = FileManager.default.enumerator(at: FirmwareBackupStore.root,
            includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where file.lastPathComponent == "transaction.json" {
            do {
                let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                if let state = object?["state"] as? String,
                   !["complete", "completed", "cancelled", "inspected"].contains(state) {
                    recoveryMessage = "A previous firmware operation needs attention. Inspect the same board and use its verified backup to retry or restore. Journal: \(file.path)"
                }
            } catch { report("Could not read the firmware recovery journal: \(error.localizedDescription)") }
        }
    }

    private func report(_ text: String) {
        error = text
        message = text
        Log.info("Matrix firmware: \(text)")
    }
}
