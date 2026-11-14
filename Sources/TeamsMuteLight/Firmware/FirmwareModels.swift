import CryptoKit
import Foundation

enum FirmwareFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

struct FirmwareManifest: Codable {
    let formatVersion: Int
    let chip: String
    let flashSize: Int
    let `protocol`: Int
    let buildID: String
    let image: String
    let sha256: String

    static func load(bundle: Bundle = .main) throws -> (FirmwareManifest, URL, URL) {
        guard let resources = bundle.resourceURL else {
            throw FirmwareFailure.invalid("App resources are missing. Reinstall the complete app.")
        }
        let directory = resources.appendingPathComponent("Firmware")
        let manifest = try JSONDecoder().decode(Self.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.formatVersion == 1, manifest.chip == "esp32s3",
              manifest.flashSize == 4_194_304, manifest.protocol == 4,
              manifest.image == "micmatrix.bin" else {
            throw FirmwareFailure.invalid("The bundled firmware manifest is incompatible.")
        }
        let image = directory.appendingPathComponent(manifest.image)
        try FirmwareFiles.validateImage(image, sha256: manifest.sha256)
        let helper = bundle.bundleURL.appendingPathComponent("Contents/Helpers/MicMatrixFlasher")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw FirmwareFailure.invalid("The app's firmware helper is missing. Reinstall the complete app.")
        }
        let expectedHelper = try String(contentsOf: directory.appendingPathComponent("helper-sha256.txt"),
            encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard FirmwareFiles.digest(try Data(contentsOf: helper)) == expectedHelper else {
            throw FirmwareFailure.invalid("The app's firmware helper checksum is invalid. Reinstall the complete app.")
        }
        return (manifest, image, helper)
    }
}

enum FirmwareFiles {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validateImage(_ url: URL, sha256: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FirmwareFailure.invalid("Firmware must be a regular file, not a symbolic link.")
        }
        guard values.fileSize == 4_194_304 else {
            throw FirmwareFailure.invalid("Expected a complete 4 MiB flash image.")
        }
        let data = try Data(contentsOf: url)
        guard data.count == 4_194_304, data.first == 0xE9,
              data[12] == 9, data[13] == 0,
              data[0x8000] == 0xAA, data[0x8001] == 0x50 else {
            throw FirmwareFailure.invalid("Expected a complete 4 MiB ESP32-S3 flash image.")
        }
        func littleEndian32(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        var application = false
        for entry in stride(from: 0x8000, to: 0x9000, by: 32)
            where data[entry] == 0xAA && data[entry + 1] == 0x50 {
            let offset = littleEndian32(entry + 4)
            let size = littleEndian32(entry + 8)
            guard offset >= 0x9000, size > 0, offset <= data.count, size <= data.count - offset else {
                throw FirmwareFailure.invalid("The firmware partition table exceeds the flash image.")
            }
            if data[entry + 2] == 0, size >= 24, data[offset] == 0xE9,
               data[offset + 12] == 9, data[offset + 13] == 0 {
                application = true
            }
        }
        guard application else {
            throw FirmwareFailure.invalid("No compatible ESP32-S3 application was found in the backup.")
        }
        guard digest(data) == sha256.lowercased() else {
            throw FirmwareFailure.invalid("Firmware checksum does not match. No data will be written.")
        }
    }

    static func normalizedMAC(_ value: String) -> String? {
        let hex = value.uppercased().filter { $0 != ":" && $0 != "-" }
        guard hex.count == 12, hex.allSatisfy(\.isHexDigit) else { return nil }
        return stride(from: 0, to: 12, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }
}

struct FirmwareBackup: Codable, Identifiable {
    let formatVersion: Int
    let mac: String
    let chip: String
    let flashSize: Int
    let sha256: String
    let imagePath: String
    let verified: Bool
    let role: String
    let firmware: String
    let createdAt: String
    var id: String { imagePath }

    func validate(for expectedMAC: String) throws {
        guard formatVersion == 1, verified, chip == "esp32s3", flashSize == 4_194_304,
              let identity = FirmwareFiles.normalizedMAC(mac),
              identity == FirmwareFiles.normalizedMAC(expectedMAC) else {
            throw FirmwareFailure.invalid("This backup is not verified for the selected device.")
        }
        try FirmwareFiles.validateImage(URL(fileURLWithPath: imagePath), sha256: sha256)
    }
}

struct FirmwareEvent: Decodable {
    let type: String
    let message: String?
    let mac: String?
    let chip: String?
    let flashSize: Int?
    let secured: Bool?
    let firmware: String?
    let backupPath: String?
    let metadataPath: String?
    let sha256: String?
    let progress: Double?
}

struct FirmwareRequest: Encodable {
    let operation: String
    let port: String
    let expectedMAC: String?
    let imagePath: String?
    let imageSHA256: String?
    let backupDirectory: String
    let backup: Bool
    let skipBackupConfirmed: Bool
    let restoreMetadataPath: String?
}

enum FirmwareBackupStore {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TeamsMuteLight/FirmwareBackups")
    }

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func backups(for mac: String) throws -> [(FirmwareBackup, URL)] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw FirmwareFailure.invalid("Cannot read the firmware backup folder.")
        }
        var result: [(FirmwareBackup, URL)] = []
        for case let file as URL in enumerator where file.pathExtension == "json" &&
            file.lastPathComponent != "transaction.json" {
            let data = try Data(contentsOf: file)
            // Only completed image records are eligible; journals use a different schema.
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["imagePath"] != nil, object["verified"] != nil else { continue }
            let backup = try JSONDecoder().decode(FirmwareBackup.self, from: data)
            if FirmwareFiles.normalizedMAC(backup.mac) == FirmwareFiles.normalizedMAC(mac) {
                try backup.validate(for: mac)
                result.append((backup, file))
            }
        }
        return result.sorted {
            if $0.0.role != $1.0.role { return $0.0.role == "original" }
            return $0.0.createdAt < $1.0.createdAt
        }
    }

    static func importBackup(_ source: URL, mac: String, factory: Bool) throws -> URL {
        guard let normalized = FirmwareFiles.normalizedMAC(mac) else {
            throw FirmwareFailure.invalid("Inspect this board before importing its backup.")
        }
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.fileSize == 4_194_304, values.isSymbolicLink != true else {
            throw FirmwareFailure.invalid("Select this board's complete, regular 4 MiB backup file.")
        }
        let data = try Data(contentsOf: source)
        let hash = FirmwareFiles.digest(data)
        try FirmwareFiles.validateImage(source, sha256: hash)
        let directory = root.appendingPathComponent(normalized.replacingOccurrences(of: ":", with: ""))
        try prepare(directory)
        let existing = try backups(for: normalized)
        let role = existing.contains { $0.0.role == "original" } ? "snapshot" : "original"
        let image = directory.appendingPathComponent("imported-\(UUID().uuidString).bin")
        try data.write(to: image, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: image.path)
        let record = FirmwareBackup(formatVersion: 1, mac: normalized, chip: "esp32s3",
            flashSize: data.count, sha256: hash, imagePath: image.path, verified: true,
            role: role, firmware: factory ? "stock (user-confirmed imported original)" : "imported original",
            createdAt: ISO8601DateFormatter().string(from: Date()))
        let metadata = image.deletingPathExtension().appendingPathExtension("json")
        let temporary = metadata.appendingPathExtension("partial")
        try JSONEncoder().encode(record).write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: temporary, to: metadata)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
        return metadata
    }
}
