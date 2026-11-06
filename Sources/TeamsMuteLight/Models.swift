import AppKit
import Foundation
import SwiftUI

// MARK: - Color

struct RGB: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

extension RGB {
    static let off = RGB(r: 0, g: 0, b: 0)
    static let red = RGB(r: 255, g: 0, b: 0)
    static let green = RGB(r: 0, g: 255, b: 0)
    static let dimGreen = RGB(r: 0, g: 110, b: 0)
    static let amber = RGB(r: 255, g: 130, b: 0)
    static let blue = RGB(r: 0, g: 0, b: 255)

    var isOff: Bool { r == 0 && g == 0 && b == 0 }
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Accepts "#RRGGBB", "RRGGBB", or "off".
    init?(string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "off" || s == "black" { self = .off; return }
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: UInt8((v >> 16) & 0xFF), g: UInt8((v >> 8) & 0xFF), b: UInt8(v & 0xFF))
    }

    func scaled(_ brightness: Double) -> RGB {
        let k = max(0, min(1, brightness))
        func s(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * k).rounded()))) }
        return RGB(r: s(r), g: s(g), b: s(b))
    }

    var color: Color {
        Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func c(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(r: c(ns.redComponent), g: c(ns.greenComponent), b: c(ns.blueComponent))
    }
}

// MARK: - State

enum MicState: String, Codable, CaseIterable, Identifiable {
    case notInMeeting
    case muted
    case unmuted
    case unknown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notInMeeting: return "Not in a meeting"
        case .muted: return "Muted"
        case .unmuted: return "Live (unmuted)"
        case .unknown: return "Unavailable"
        }
    }
}

struct StateColors: Codable, Equatable {
    var notInMeeting: RGB
    var muted: RGB
    var unmuted: RGB
    var unknown: RGB

    subscript(_ state: MicState) -> RGB {
        get {
            switch state {
            case .notInMeeting: return notInMeeting
            case .muted: return muted
            case .unmuted: return unmuted
            case .unknown: return unknown
            }
        }
        set {
            switch state {
            case .notInMeeting: notInMeeting = newValue
            case .muted: muted = newValue
            case .unmuted: unmuted = newValue
            case .unknown: unknown = newValue
            }
        }
    }

    /// Dedicated mute light: dark when idle, red when live, dim green when muted.
    static let muteLight = StateColors(notInMeeting: .off, muted: .dimGreen, unmuted: .red, unknown: .off)
    /// Kuando-only: the one light doubles as presence + mute indicator.
    static let kuandoOnly = StateColors(notInMeeting: .green, muted: .amber, unmuted: .red, unknown: .off)
}

enum DetectionMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case teamsAPI
    case accessibility

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic (Teams API when available)"
        case .teamsAPI: return "Teams local API"
        case .accessibility: return "Read the Teams mute button (recommended)"
        }
    }
}

enum WebhookFormat: String, Codable, CaseIterable, Identifiable {
    case generic
    case wled
    var id: String { rawValue }
    var label: String { self == .generic ? "Generic JSON" : "WLED (/json/state)" }
}

// MARK: - Settings

// MARK: - Effects

enum LightEffect: String, Codable, CaseIterable, Identifiable {
    case solid
    case pulse
    case flash

    var id: String { rawValue }
    var label: String {
        switch self {
        case .solid: return "Solid"
        case .pulse: return "Pulse"
        case .flash: return "Flash"
        }
    }
}

struct StateEffect: Codable, Equatable {
    var effect: LightEffect = .solid
    /// Cycles per second for pulse / flash.
    var rateHz: Double = 1.0
}

struct StateEffects: Codable, Equatable {
    var notInMeeting = StateEffect()
    var muted = StateEffect()
    var unmuted = StateEffect(effect: .pulse, rateHz: 1.0)
    var unknown = StateEffect()

    subscript(_ state: MicState) -> StateEffect {
        get {
            switch state {
            case .notInMeeting: return notInMeeting
            case .muted: return muted
            case .unmuted: return unmuted
            case .unknown: return unknown
            }
        }
        set {
            switch state {
            case .notInMeeting: notInMeeting = newValue
            case .muted: muted = newValue
            case .unmuted: unmuted = newValue
            case .unknown: unknown = newValue
            }
        }
    }
}

struct OutputConfig: Codable, Equatable {
    var enabled: Bool
    var brightness: Double = 1.0
    var colors: StateColors
    /// Empty = first matching device.
    var deviceSerial: String = ""
}

struct HomeAssistantConfig: Codable, Equatable {
    var light = OutputConfig(enabled: false, colors: .muteLight)
    var baseURL = "http://homeassistant.local:8123"
    var entityID = "light.mic_status"
}

struct WebhookConfig: Codable, Equatable {
    var light = OutputConfig(enabled: false, colors: .muteLight)
    var url = ""
    var format: WebhookFormat = .generic
}

struct AppSettings: Codable, Equatable {
    var detection: DetectionMode = .accessibility
    var axPollInterval: Double = 0.5
    /// Button label meaning "you are currently MUTED" (the button offers to unmute).
    var axMutedPattern = #"^unmute(\s+mic|\s*\(|$)"#
    /// Button label meaning "you are currently UNMUTED" (the button offers to mute).
    var axUnmutedPattern = #"^mute(\s+mic|\s*\(|$)"#

    var kuando = OutputConfig(enabled: true, colors: .muteLight)
    var blinkStick = OutputConfig(enabled: false, colors: .muteLight)
    var blinkStickLEDCount = 2
    var homeAssistant = HomeAssistantConfig()
    var webhook = WebhookConfig()

    var effects = StateEffects()
    var callStartRainbow = true
    var rainbowDuration: Double = 1.5

    init() {}

    // Lenient decoding so adding fields later never wipes a user's config.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        detection = (try? c.decodeIfPresent(DetectionMode.self, forKey: .detection)) ?? d.detection
        axPollInterval = (try? c.decodeIfPresent(Double.self, forKey: .axPollInterval)) ?? d.axPollInterval
        axMutedPattern = (try? c.decodeIfPresent(String.self, forKey: .axMutedPattern)) ?? d.axMutedPattern
        axUnmutedPattern = (try? c.decodeIfPresent(String.self, forKey: .axUnmutedPattern)) ?? d.axUnmutedPattern
        kuando = (try? c.decodeIfPresent(OutputConfig.self, forKey: .kuando)) ?? d.kuando
        blinkStick = (try? c.decodeIfPresent(OutputConfig.self, forKey: .blinkStick)) ?? d.blinkStick
        blinkStickLEDCount = (try? c.decodeIfPresent(Int.self, forKey: .blinkStickLEDCount)) ?? d.blinkStickLEDCount
        homeAssistant = (try? c.decodeIfPresent(HomeAssistantConfig.self, forKey: .homeAssistant)) ?? d.homeAssistant
        webhook = (try? c.decodeIfPresent(WebhookConfig.self, forKey: .webhook)) ?? d.webhook
        effects = (try? c.decodeIfPresent(StateEffects.self, forKey: .effects)) ?? d.effects
        callStartRainbow = (try? c.decodeIfPresent(Bool.self, forKey: .callStartRainbow)) ?? d.callStartRainbow
        rainbowDuration = (try? c.decodeIfPresent(Double.self, forKey: .rainbowDuration)) ?? d.rainbowDuration
    }

    private static let defaultsKey = "AppSettings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
