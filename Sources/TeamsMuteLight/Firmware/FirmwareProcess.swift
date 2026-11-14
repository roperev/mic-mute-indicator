import Foundation

/// One child process owns the serial connection for the complete transaction.
final class FirmwareProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let reader = DispatchQueue(label: "TeamsMuteLight.firmware-helper-output")
    private var requestURL: URL?
    var onEvent: ((FirmwareEvent) -> Void)?
    var onExit: ((Int32, String?) -> Void)?

    func start(helper: URL, request: FirmwareRequest) throws {
        let directory = FirmwareBackupStore.root.appendingPathComponent("Requests")
        try FirmwareBackupStore.prepare(directory)
        let file = directory.appendingPathComponent("\(UUID().uuidString).json")
        try JSONEncoder().encode(request).write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        requestURL = file
        process.executableURL = helper
        process.arguments = ["--request", file.path]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = [
            "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(),
            "TMPDIR": NSTemporaryDirectory(), "PYTHONNOUSERSITE": "1",
            "LANG": "en_US.UTF-8", "TERM": "dumb",
        ]
        // Drain library chatter without adding arbitrary device output to public app logs.
        errors.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        do {
            try process.run()
        } catch {
            errors.fileHandleForReading.readabilityHandler = nil
            try FileManager.default.removeItem(at: file)
            throw error
        }
        reader.async { [self] in
            var buffer = Data()
            var parsingError: String?
            func rejectStatus(_ message: String) {
                if parsingError == nil {
                    parsingError = message
                    do { try send(command: "cancel", mac: nil) }
                    catch { parsingError = "\(message) Could not request safe cancellation." }
                }
            }
            while true {
                let bytes = output.fileHandleForReading.availableData
                if bytes.isEmpty { break }
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer.prefix(upTo: newline))
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard line.count < 64 * 1024 else {
                        rejectStatus("Firmware helper returned an oversized status message.")
                        continue
                    }
                    do {
                        let event = try JSONDecoder().decode(FirmwareEvent.self, from: line)
                        if parsingError == nil {
                            DispatchQueue.main.async { self.onEvent?(event) }
                        }
                    } catch {
                        rejectStatus("Firmware helper returned an invalid status message.")
                    }
                }
                if buffer.count > 64 * 1024 {
                    rejectStatus("Firmware helper output exceeded the status limit.")
                    buffer.removeAll()
                }
            }
            if !buffer.isEmpty { parsingError = "Firmware helper status was truncated." }
            process.waitUntilExit()
            errors.fileHandleForReading.readabilityHandler = nil
            var cleanupError: String?
            do { try FileManager.default.removeItem(at: file) }
            catch { cleanupError = "Could not remove the temporary firmware request." }
            let failure = parsingError ?? cleanupError
            DispatchQueue.main.async {
                self.onExit?(self.process.terminationStatus, failure)
            }
        }
    }

    func send(command: String, mac: String?) throws {
        var object = ["command": command]
        if let mac { object["mac"] = mac }
        var data = try JSONEncoder().encode(object)
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
    }
}
