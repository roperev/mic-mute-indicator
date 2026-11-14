import Foundation

/// Client for the Microsoft Teams "third-party app API" (new Teams):
///   Teams > Settings > Privacy > Third-party app API > Manage API > Enable API
///
/// Teams runs a local WebSocket server on ws://127.0.0.1:8124. Unpaired clients only get
/// `meetingPermissions` (incl. `canPair`). Once you send any command while in a meeting, Teams
/// shows an "allow new device" prompt; on approval it sends `tokenRefresh`, and from then on
/// `meetingState` (isMuted, isInMeeting, ...) is pushed on every change.
///
/// Delegate + completion callbacks run on the main queue.
final class TeamsAPIMonitor: NSObject, URLSessionWebSocketDelegate {
    enum Status: String, Equatable {
        case stopped = "Stopped"
        case disconnected = "Not connected (is Teams running with the API enabled?)"
        case connecting = "Connecting…"
        case connected = "Connected, not paired"
        case paired = "Paired"
    }

    struct Snapshot: Equatable {
        var status: Status = .stopped
        var isMuted: Bool?
        var isInMeeting: Bool?
        var canPair = false
        var canToggleMute = false
        var lastError: String?
    }

    var onChange: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot() {
        didSet { if snapshot != oldValue { onChange?(snapshot) } }
    }

    static let appName = "TeamsMuteLight"
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0.0"

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var requestID = 0
    private var reconnectDelay: TimeInterval = 2
    private var reconnectWork: DispatchWorkItem?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    var hasToken: Bool { !(Keychain.get(.teamsToken) ?? "").isEmpty }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        connect()
    }

    func stop() {
        running = false
        reconnectWork?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        snapshot = Snapshot()
    }

    /// Reconnect immediately (e.g. Teams just launched).
    func reconnectNow() {
        guard running else { return }
        if snapshot.status == .connected || snapshot.status == .paired { return }
        reconnectWork?.cancel()
        reconnectDelay = 2
        teardown()
        connect()
    }

    func forgetPairing() {
        Keychain.set(nil, for: .teamsToken)
        Log.info("Teams API pairing token cleared")
        guard running else { return }
        teardown()
        connect()
    }

    private func connect() {
        guard running, task == nil else { return }
        var c = URLComponents()
        c.scheme = "ws"
        c.host = "127.0.0.1"
        c.port = 8124
        c.queryItems = [
            URLQueryItem(name: "token", value: Keychain.get(.teamsToken) ?? ""),
            URLQueryItem(name: "protocol-version", value: "2.0.0"),
            URLQueryItem(name: "manufacturer", value: "DIY"),
            URLQueryItem(name: "device", value: "MacMuteLight"),
            URLQueryItem(name: "app", value: Self.appName),
            URLQueryItem(name: "app-version", value: Self.appVersion),
        ]
        guard let url = c.url else { return }
        var s = snapshot
        s.status = .connecting
        snapshot = s
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 256 * 1024
        task = t
        t.resume()
        receive(on: t)
    }

    private func teardown() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func handleDisconnect(_ reason: String) {
        guard task != nil else { return }
        teardown()
        snapshot = Snapshot(status: .disconnected, lastError: reason)
        guard running else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay, execute: work)
        reconnectDelay = min(reconnectDelay * 2, 30)
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        reconnectDelay = 2
        var s = snapshot
        s.status = .connected
        s.lastError = nil
        snapshot = s
        Log.info("Teams API connected\(hasToken ? " (have token)" : " (no token yet — join a meeting and choose Pair)")")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        handleDisconnect("closed (\(closeCode.rawValue))")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        handleDisconnect(error?.localizedDescription ?? "connection ended")
    }

    // MARK: Messages

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async { self?.handleReceive(result, on: t) }
        }
    }

    private func handleReceive(_ result: Result<URLSessionWebSocketTask.Message, Error>, on t: URLSessionWebSocketTask) {
        guard t === task else { return }
        switch result {
        case .success(let message):
            switch message {
            case .string(let s): handle(Data(s.utf8))
            case .data(let d): handle(d)
            @unknown default: break
            }
            receive(on: t)
        case .failure(let error):
            handleDisconnect(error.localizedDescription)
        }
    }

    private struct Message: Decodable {
        struct MeetingUpdate: Decodable {
            struct State: Decodable {
                var isMuted: Bool?
                var isInMeeting: Bool?
            }
            struct Permissions: Decodable {
                var canToggleMute: Bool?
                var canPair: Bool?
            }
            var meetingState: State?
            var meetingPermissions: Permissions?
        }
        var meetingUpdate: MeetingUpdate?
        var tokenRefresh: String?
        var requestId: Int?
        var response: String?
        var errorMsg: String?
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9\-]{8,128}$"#)

    private func handle(_ data: Data) {
        guard let m = try? JSONDecoder().decode(Message.self, from: data) else { return }
        var s = snapshot

        if let token = m.tokenRefresh,
           Self.tokenPattern.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil {
            Keychain.set(token, for: .teamsToken)
            s.status = .paired
            Log.info("Teams API paired — token saved to Keychain")
        }
        if let u = m.meetingUpdate {
            if let p = u.meetingPermissions {
                s.canPair = p.canPair ?? false
                s.canToggleMute = p.canToggleMute ?? false
            }
            if let st = u.meetingState {
                s.status = .paired
                s.isMuted = st.isMuted
                s.isInMeeting = st.isInMeeting
            }
        }
        if let r = m.response { Log.info("Teams API response: \(r.prefix(200))") }
        if let e = m.errorMsg { Log.info("Teams API error: \(e.prefix(200))"); s.lastError = String(e.prefix(200)) }
        snapshot = s
    }

    // MARK: Commands (accepted only once paired, but sending one is what triggers pairing)

    func send(action: String) {
        guard let t = task else { return }
        requestID += 1
        let payload: [String: Any] = ["action": action, "parameters": [String: Any](), "requestId": requestID]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        t.send(.string(text)) { error in
            if let error { Log.info("Teams API send failed: \(error.localizedDescription)") }
        }
    }

    /// Must be in a meeting. Teams pops an "allow" prompt; note this toggles mute once if approved.
    func pair() { send(action: "toggle-mute") }
    func toggleMute() { send(action: "toggle-mute") }
}
