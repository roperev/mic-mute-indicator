import Foundation
import os
import Security

// MARK: - Logging

enum Log {
    private static let logger = Logger(subsystem: "com.eroper.TeamsMuteLight", category: "app")
    /// CLI mode echoes log lines to stdout.
    static var echoToStdout = false

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        if echoToStdout { print("[log] \(message)") }
        DispatchQueue.main.async { EventLog.shared.append(message) }
    }
}

/// Small in-memory ring buffer shown in Settings > Log. Main thread only.
final class EventLog: ObservableObject {
    static let shared = EventLog()
    @Published private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func append(_ s: String) {
        lines.append("\(formatter.string(from: Date()))  \(s)")
        if lines.count > 300 { lines.removeFirst(lines.count - 300) }
    }

    var text: String { lines.joined(separator: "\n") }
}

// MARK: - Keychain (secrets never go in UserDefaults)

enum Keychain {
    private static let service = "com.eroper.TeamsMuteLight"

    enum Account: String {
        case teamsToken = "teams-api-token"
        case homeAssistantToken = "home-assistant-token"
    }

    static func get(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String?, for account: Account) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.info("Keychain write failed (\(status)) for \(account.rawValue)") }
    }
}
