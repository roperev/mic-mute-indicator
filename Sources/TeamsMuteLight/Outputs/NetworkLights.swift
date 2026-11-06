import Foundation

private let httpSession: URLSession = {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 5
    cfg.timeoutIntervalForResource = 10
    return URLSession(configuration: cfg)
}()

private func validHTTPURL(_ s: String) -> URL? {
    guard let url = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host != nil else { return nil }
    return url
}

// MARK: - Home Assistant

/// Calls light.turn_on / light.turn_off on a Home Assistant light entity via the REST API.
/// Uses a long-lived access token (Profile -> Security -> Long-lived access tokens), stored in the Keychain.
final class HomeAssistantLight: LightOutput {
    let name = "Home Assistant"
    let supportsAnimation = false
    var baseURL = ""
    var entityID = ""
    var token = ""

    private var lastSent: (RGB, Double)?
    private(set) var statusText = "Not configured"

    private static let entityPattern = try! NSRegularExpression(pattern: #"^light\.[a-z0-9_]+$"#)

    func apply(state: MicState, color: RGB, brightness: Double) {
        if let last = lastSent, last.0 == color, last.1 == brightness { return }
        send(color: color, brightness: brightness, force: false)
    }

    func release() {
        lastSent = nil
    }

    /// Re-send even if unchanged (used by "Send test").
    func send(color: RGB, brightness: Double, force: Bool) {
        guard let base = validHTTPURL(baseURL) else { statusText = "Invalid base URL"; return }
        let entity = entityID.trimmingCharacters(in: .whitespaces)
        guard Self.entityPattern.firstMatch(in: entity, range: NSRange(entity.startIndex..., in: entity)) != nil else {
            statusText = "Entity must look like light.my_light"; return
        }
        guard !token.isEmpty else { statusText = "Missing access token"; return }

        let off = color.isOff || brightness <= 0
        let url = base.appendingPathComponent("api/services/light/\(off ? "turn_off" : "turn_on")")
        var body: [String: Any] = ["entity_id": entity]
        if !off {
            body["rgb_color"] = [Int(color.r), Int(color.g), Int(color.b)]
            body["brightness"] = Int((max(0, min(1, brightness)) * 255).rounded())
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        lastSent = (color, brightness)
        httpSession.dataTask(with: req) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.statusText = "Error: \(error.localizedDescription)"
                    self.lastSent = nil // retry on next state change
                    Log.info("Home Assistant request failed: \(error.localizedDescription)")
                } else if (200..<300).contains(code) {
                    self.statusText = "OK (\(off ? "off" : color.hex))"
                } else {
                    self.statusText = "HTTP \(code)"
                    self.lastSent = nil
                    Log.info("Home Assistant returned HTTP \(code)")
                }
            }
        }.resume()
    }
}

// MARK: - Webhook / WLED

/// POSTs state changes to any URL. Handy for DIY lights (ESP32, WLED, Home Assistant webhook triggers, Node-RED...).
///
/// Generic payload:  {"state":"muted","color":"#FF0000","r":255,"g":0,"b":0,"brightness":1.0}
/// WLED payload:     {"on":true,"bri":255,"seg":[{"col":[[255,0,0]]}]}   (POST to http://<wled-ip>/json/state)
final class WebhookLight: LightOutput {
    let name = "Webhook"
    let supportsAnimation = false
    var url = ""
    var format: WebhookFormat = .generic

    private var lastSent: (MicState, RGB, Double)?
    private(set) var statusText = "Not configured"

    func apply(state: MicState, color: RGB, brightness: Double) {
        if let l = lastSent, l.0 == state, l.1 == color, l.2 == brightness { return }
        send(state: state, color: color, brightness: brightness)
    }

    func release() { lastSent = nil }

    func send(state: MicState, color: RGB, brightness: Double) {
        guard let target = validHTTPURL(url) else { statusText = "Invalid URL"; return }
        let body: [String: Any]
        switch format {
        case .generic:
            body = ["state": state.rawValue, "color": color.hex,
                    "r": Int(color.r), "g": Int(color.g), "b": Int(color.b), "brightness": brightness]
        case .wled:
            let off = color.isOff || brightness <= 0
            body = off ? ["on": false]
                : ["on": true, "bri": Int((max(0, min(1, brightness)) * 255).rounded()),
                   "seg": [["col": [[Int(color.r), Int(color.g), Int(color.b)]]]]]
        }
        var req = URLRequest(url: target)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        lastSent = (state, color, brightness)
        httpSession.dataTask(with: req) { [weak self] _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.statusText = "Error: \(error.localizedDescription)"
                    self.lastSent = nil
                } else {
                    self.statusText = (200..<300).contains(code) ? "OK (\(state.rawValue))" : "HTTP \(code)"
                    if !(200..<300).contains(code) { self.lastSent = nil }
                }
            }
        }.resume()
    }
}
