import AppKit
import Foundation

private final class FakeFirmwareActivity: FirmwareTerminationState {
    var busy = true
    var protectedOperation = true
    var showingProgress = false
    var cancellations = 0
    func cancel() { cancellations += 1 }
}

@main
enum FirmwareTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.contains("--request") {
            try fakeHelper()
            return
        }
        let activity = FakeFirmwareActivity()
        FirmwareApplicationDelegate.manager = activity
        let delegate = FirmwareApplicationDelegate()
        var notices = 0
        delegate.blockedQuitNotification = { notices += 1 }
        let app = NSApplication.shared
        for _ in 0..<3 {
            precondition(delegate.applicationShouldTerminate(app) == .terminateCancel)
        }
        precondition(activity.showingProgress && notices == 3 && activity.cancellations == 0,
            "Protected Quit must neither cancel the helper nor tear down output")
        activity.busy = false
        precondition(delegate.applicationShouldTerminate(app) == .terminateNow,
            "Normal termination must be restored after firmware cleanup")
        activity.busy = true
        activity.protectedOperation = false
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        precondition(activity.cancellations == 1, "Pre-erase Quit must wait for safe cancellation")
        FirmwareApplicationDelegate.manager = nil

        precondition(FirmwareFiles.normalizedMAC("d4-05-92-40-89-a0") == "D4:05:92:40:89:A0")
        for invalid in ["", "AA", "D4:05:92:40:89:ZZ", "../../device"] {
            precondition(FirmwareFiles.normalizedMAC(invalid) == nil)
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("firmware-tests-\(UUID().uuidString)")
        try FirmwareBackupStore.prepare(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("original.bin")
        var bytes = Data(repeating: 0xFF, count: 4_194_304)
        bytes[0] = 0xE9
        bytes[12] = 9
        bytes[13] = 0
        bytes.replaceSubrange(0x8000..<0x8020, with: Data(repeating: 0, count: 32))
        bytes[0x8000] = 0xAA
        bytes[0x8001] = 0x50
        bytes[0x8006] = 1
        bytes[0x800A] = 0x14
        bytes[0x10000] = 0xE9
        bytes[0x1000C] = 9
        bytes[0x1000D] = 0
        try bytes.write(to: file)
        let hash = FirmwareFiles.digest(bytes)
        try FirmwareFiles.validateImage(file, sha256: hash)
        var wrongChip = bytes
        wrongChip[12] = 0
        try wrongChip.write(to: file)
        expectFailure { try FirmwareFiles.validateImage(file, sha256: FirmwareFiles.digest(wrongChip)) }
        try bytes.write(to: file)
        let record = FirmwareBackup(formatVersion: 1, mac: "D4:05:92:40:89:A0",
            chip: "esp32s3", flashSize: bytes.count, sha256: hash, imagePath: file.path,
            verified: true, role: "original", firmware: "stock", createdAt: "test")
        try record.validate(for: record.mac)
        expectFailure { try record.validate(for: "00:00:00:00:00:01") }
        bytes[100] = 0
        try bytes.write(to: file)
        expectFailure { try record.validate(for: record.mac) }
        try Data(bytes.prefix(100)).write(to: file)
        expectFailure { try FirmwareFiles.validateImage(file, sha256: hash) }
        let link = directory.appendingPathComponent("linked.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        expectFailure { try FirmwareFiles.validateImage(link, sha256: hash) }
        try testProcess(directory: directory)
        print("Firmware tests passed: native termination guard, device identities, backup hashes, wrong-device, truncated-image and symlink rejection.")
    }

    static func expectFailure(_ action: () throws -> Void) {
        do {
            try action()
            preconditionFailure("An unsafe firmware input was accepted")
        } catch { }
    }

    static func fakeHelper() throws {
        let file = CommandLine.arguments[2]
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: file))) as! [String: Any]
        if object["operation"] as? String == "inspect" {
            FileHandle.standardOutput.write(Data("not-json\n".utf8))
            return
        }
        FileHandle.standardOutput.write(Data("{\"type\":\"readyToWrite\"}\n".utf8))
        guard let line = readLine(), let data = line.data(using: .utf8),
              let command = try JSONSerialization.jsonObject(with: data) as? [String: String],
              command["command"] == "authorizeWrite", command["mac"] == "D4:05:92:40:89:A0" else {
            exit(2)
        }
        let complete = Data("{\"type\":\"complete\",\"message\":\"Verified fake transaction\"}\n".utf8)
        FileHandle.standardOutput.write(complete.prefix(9))
        Thread.sleep(forTimeInterval: 0.02)
        FileHandle.standardOutput.write(complete.dropFirst(9))
    }

    static func testProcess(directory: URL) throws {
        for operation in ["install", "inspect"] {
            let runner = FirmwareProcess()
            var finished = false
            var completed = false
            var statusCode: Int32?
            var failure: String?
            runner.onEvent = { event in
                if event.type == "readyToWrite" {
                    do { try runner.send(command: "authorizeWrite", mac: "D4:05:92:40:89:A0") }
                    catch { preconditionFailure("Fake write approval failed: \(error)") }
                }
                if event.type == "complete" { completed = true }
            }
            runner.onExit = { code, error in
                statusCode = code
                failure = error
                finished = true
            }
            let request = FirmwareRequest(operation: operation, port: "/dev/cu.fake",
                expectedMAC: "D4:05:92:40:89:A0", imagePath: nil, imageSHA256: nil,
                backupDirectory: directory.path, backup: true, skipBackupConfirmed: false,
                restoreMetadataPath: nil)
            try runner.start(helper: URL(fileURLWithPath: CommandLine.arguments[0]), request: request)
            let deadline = Date().addingTimeInterval(5)
            while !finished && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(finished && statusCode == 0)
            if operation == "install" {
                precondition(completed && failure == nil, "Chunked progress must reach completion after explicit approval")
            } else {
                precondition(!completed && failure != nil, "Malformed helper output must not become success")
            }
        }
        print("Firmware process tests passed: contained executable invocation, explicit write gate, chunked JSON, invalid JSON and exit handling.")
    }
}
