import Foundation

struct MatrixDisplayAvailability {
    var locked = false
    var sessionInactive = false
    var displayAsleep = false
    var systemAsleep = false

    func shouldBlank(state: MicState) -> Bool {
        let inCall = state == .muted || state == .unmuted
        return !inCall && (locked || sessionInactive || displayAsleep || systemAsleep)
    }
}

enum MatrixIcon: String, Codable, CaseIterable, Identifiable {
    case microphone, mutedMicrophone, fire, prohibited, check, dot, orientation, off
    case heart, shield, rainbow, headphones, moon
    case afk, smiley, shrug
    case warning
    static let allCases: [MatrixIcon] = [.microphone, .mutedMicrophone, .fire, .prohibited,
        .check, .dot, .orientation, .warning, .heart, .shield, .rainbow, .headphones, .moon,
        .afk, .smiley, .shrug]
    var id: String { rawValue }

    var label: String {
        switch self {
        case .microphone: return "Microphone"
        case .mutedMicrophone: return "Muted microphone"
        case .fire: return "Fire"
        case .prohibited: return "No sign"
        case .check: return "Check"
        case .dot: return "Dot"
        case .orientation: return "Up arrow + lower-left dot"
        case .off: return "Off"
        case .warning: return "Warning"
        case .heart: return "Heart"
        case .shield: return "Adobe A"
        case .rainbow: return "Rainbow"
        case .headphones: return "Headphones"
        case .moon: return "Moon"
        case .afk: return "AFK"
        case .smiley: return "Smiley"
        case .shrug: return "Shrug"
        }
    }

    /// Top-to-bottom rows, most significant bit at the left of each row.
    var bitmap: UInt64 {
        switch self {
        case .microphone: return 0x181818185A3C1818
        case .mutedMicrophone: return 0x985838185A3C1A19
        case .fire: return 0x0818387A7E7E3C18
        case .check: return 0x000103064C783000
        case .dot: return 0x0000183C3C180000
        case .orientation: return 0x183C7E1818181880
        case .off: return 0
        case .heart, .shield, .rainbow, .headphones, .moon, .prohibited, .afk, .smiley, .shrug, .warning:
            return artwork.enumerated().reduce(UInt64(0)) { result, entry in
                entry.element.isOff ? result : result | (UInt64(1) << (63 - entry.offset))
            }
        }
    }

    var artwork: [RGB] {
        artwork(at: self == .shrug ? MatrixIconAnimation.shrugPreviewTime : 0)
    }

    var isAnimated: Bool { self == .afk || self == .shrug }

    func artwork(at time: TimeInterval) -> [RGB] {
        if self == .shrug { return MatrixIconAnimation.shrug(at: time) }
        let rows: [String]
        switch self {
        case .microphone:
            rows = ["...WW...", "..WRRW..", "..WDRW..", "..WDRW..", ".R.WW.R.", ".RRWWRR.", "...RR...", "..RRRR.."]
        case .mutedMicrophone:
            rows = ["R..WW...", ".RWGGW..", "..REGW..", "..WRGW..", ".G.WRG..", ".GGWGR..", "...GG.R.", "..GGGG.R"]
        case .fire:
            rows = ["....R...", "...RO...", "..ROO.R.", "..ROYOOR", ".ROYWWOR", ".ROYWYOR", "..ROYO..", "...RR..."]
        case .prohibited:
            rows = ["..SRRS..", ".R....R.", "R....R.R", "R...R..R", "R..R...R", "R.R....R", ".R....R.", "..SRRS.."]
        case .check:
            rows = ["........", "......W.", ".....WG.", ".C..WG..", ".CWGG...", "..GG....", "........", "........"]
        case .dot:
            rows = ["........", "...DD...", "..DRRD..", ".DRSSRD.", ".DRSSRD.", "..DRRD..", "...DD...", "........"]
        case .orientation:
            rows = ["...WW...", "..WCCW..", ".WCCCCW.", "...CC...", "...CC...", "...CC...", "...CC...", "O......."]
        case .heart:
            rows = ["........", ".PP..RR.", "PWWPRRRR", "PPRRRRRR", ".PRRRRR.", "..RRRR..", "...RR...", "........"]
        case .shield:
            rows = ["...HH...", "..JAAJ..", "..HAAH..", ".JAAAAJ.", ".AA..AA.", ".AA..AA.", "HAAA.AAH", "AAAAA.AA"]
        case .rainbow:
            rows = ["..RRRR..", ".ROOOOR.", "ROYYYYOR", "ROYGGYOR", "OYGBBGYO", "YGB..BGY", "GB....BG", "........"]
        case .headphones:
            rows = ["..CCCC..", ".CB..BC.", "CB....BC", "C......C", "PW....WP", "PB....BP", "PP....PP", "........"]
        case .moon:
            rows = ["...YY...", "..YW....", ".YW.....", ".YW...B.", ".YW.....", "..YW..C.", "...YYY..", "........"]
        case .afk:
            rows = MatrixIconAnimation.afkRows(at: time)
        case .smiley:
            rows = ["..WYYW..", ".YYYYYY.", "YY.YY.YY", "YY.YY.YY", "YYYYYYYY", "Y.YYYY.Y", ".Y....Y.", "..YYYY.."]
        case .shrug:
            preconditionFailure("Shrug uses the scrolling glyph renderer")
        case .off:
            rows = Array(repeating: "........", count: 8)
        case .warning:
            rows = ["...YY...", "...RR...", "...RR...", "...RR...", "...RR...", "........", "...YY...", "...RR..."]
        }
        let palette: [Character: RGB] = [
            ".": .off, "W": RGB(r: 255, g: 245, b: 220),
            "C": RGB(r: 0, g: 210, b: 255), "B": RGB(r: 25, g: 65, b: 200),
            "R": RGB(r: 255, g: 35, b: 45), "O": RGB(r: 255, g: 110, b: 0),
            "Y": RGB(r: 255, g: 210, b: 20), "G": RGB(r: 35, g: 255, b: 95),
            "P": RGB(r: 235, g: 65, b: 180),
            "D": RGB(r: 145, g: 12, b: 25), "S": RGB(r: 255, g: 100, b: 85),
            "E": RGB(r: 10, g: 135, b: 35),
            "A": RGB(r: 250, g: 15, b: 0), "H": RGB(r: 210, g: 10, b: 0),
            "J": RGB(r: 120, g: 5, b: 0),
        ]
        precondition(rows.count == 8 && rows.allSatisfy { $0.count == 8 }, "Artwork must be exactly 8x8")
        return rows.flatMap { row in row.map { symbol in
            guard let color = palette[symbol] else { preconditionFailure("Unknown artwork palette symbol") }
            return color
        } }
    }
}

enum MatrixIconAnimation {
    static let letterDuration = 0.8
    static let scrollPixelsPerSecond = 8.0

    static func afkRows(at time: TimeInterval) -> [String] {
        precondition(time.isFinite, "Animation time must be finite")
        let phase = Int((max(0, time) / letterDuration).truncatingRemainder(dividingBy: 3))
        switch phase {
        case 0: return ["..WWCC..", ".CC..CC.", ".CC..CC.", ".CCCCCC.", ".CC..CC.", ".CC..CC.", ".CC..CC.", "........"]
        case 1: return [".WWYYYY.", ".YY.....", ".YY.....", ".YYYYY..", ".YY.....", ".YY.....", ".YY.....", "........"]
        default: return [".WG..GG.", ".GG.GG..", ".GGGG...", ".GGG....", ".GGGG...", ".GG.GG..", ".GG..GG.", "........"]
        }
    }

    // The literal shrug's glyphs, in reading order: macron, backslash, _, (, ツ, ), _, /, macron.
    static let shrugGlyphs: [[String]] = [
        ["###", "...", "...", "...", "...", "...", "...", "..."],
        ["#..", "#..", ".#.", ".#.", "..#", "..#", "...", "..."],
        ["...", "...", "...", "...", "...", "...", "###", "..."],
        ["..#", ".#.", "#..", "#..", "#..", ".#.", "..#", "..."],
        [".....", ".#.#.", ".#.#.", "....#", "....#", "...#.", ".##..", "....."],
        ["#..", ".#.", "..#", "..#", "..#", ".#.", "#..", "..."],
        ["...", "...", "...", "...", "...", "...", "###", "..."],
        ["..#", "..#", ".#.", ".#.", "#..", "#..", "...", "..."],
        ["###", "...", "...", "...", "...", "...", "...", "..."],
    ]
    static let shrugRows: [[Bool]] = (0..<8).map { row in
        shrugGlyphs.flatMap { glyph in glyph[row].map { $0 == "#" } + [false] }
    }
    static var shrugWidth: Int { shrugRows[0].count }
    static var shrugPreviewTime: Double { Double(shrugWidth / 2 + 4) / scrollPixelsPerSecond }

    static func shrug(at time: TimeInterval) -> [RGB] {
        precondition(time.isFinite, "Animation time must be finite")
        let cycle = shrugWidth + 8
        let step = Int((max(0, time) * scrollPixelsPerSecond).truncatingRemainder(dividingBy: Double(cycle)))
        let left = 8 - step
        return (0..<64).map { index in
            let sourceX = index % 8 - left
            let row = index / 8
            guard sourceX >= 0, sourceX < shrugWidth, shrugRows[row][sourceX] else { return .off }
            return row < 3 ? RGB(r: 255, g: 245, b: 220) : RGB(r: 255, g: 210, b: 20)
        }
    }
}

struct MatrixIcons: Codable, Equatable {
    var notInMeeting: MatrixIcon = .shield
    var muted: MatrixIcon = .mutedMicrophone
    var unmuted: MatrixIcon = .dot
    var unknown: MatrixIcon = .warning

    subscript(_ state: MicState) -> MatrixIcon {
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

enum MatrixColorStyle: String, Codable, CaseIterable, Identifiable {
    case artwork, tinted, solid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .artwork: return "Full color"
        case .tinted: return "Tint artwork"
        case .solid: return "Single color"
        }
    }
}

struct MatrixColorStyles: Codable, Equatable {
    var notInMeeting: MatrixColorStyle = .artwork
    var muted: MatrixColorStyle = .artwork
    var unmuted: MatrixColorStyle = .artwork
    var unknown: MatrixColorStyle = .artwork

    subscript(_ state: MicState) -> MatrixColorStyle {
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

struct MatrixBrightnessLevels: Codable, Equatable {
    var notInMeeting = 0.20
    var muted = 0.75
    var unmuted = 1.0
    var unknown = 1.0

    init() {}

    static var legacy: MatrixBrightnessLevels {
        var levels = MatrixBrightnessLevels()
        levels.notInMeeting = 1
        levels.muted = 1
        return levels
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func level(_ key: CodingKeys) throws -> Double {
            let value = try c.decodeIfPresent(Double.self, forKey: key) ?? 1
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c,
                    debugDescription: "Relative matrix brightness must be finite")
            }
            return max(0, min(1, value))
        }
        notInMeeting = try level(.notInMeeting)
        muted = try level(.muted)
        unmuted = try level(.unmuted)
        unknown = try level(.unknown)
    }

    subscript(_ state: MicState) -> Double {
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

struct MatrixConfig: Codable, Equatable {
    var light = OutputConfig(enabled: false, brightness: MatrixFrame.defaultLevel,
        colors: StateColors(notInMeeting: .red, muted: .green, unmuted: .red, unknown: .off))
    var icons = MatrixIcons()
    var rotation = 0
    var mirrored = false
    var fullColor = true
    var colorStyles = MatrixColorStyles()
    var brightnessLevels = MatrixBrightnessLevels()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MatrixConfig()
        light = try c.decodeIfPresent(OutputConfig.self, forKey: .light) ?? d.light
        light.brightness = light.brightness.isFinite
            ? LightBrightness.clamped(light.brightness, maximum: MatrixFrame.maxLevel) : d.light.brightness
        icons = try c.decodeIfPresent(MatrixIcons.self, forKey: .icons) ?? d.icons
        rotation = max(0, min(3, try c.decodeIfPresent(Int.self, forKey: .rotation) ?? d.rotation))
        mirrored = try c.decodeIfPresent(Bool.self, forKey: .mirrored) ?? d.mirrored
        fullColor = try c.decodeIfPresent(Bool.self, forKey: .fullColor) ?? d.fullColor
        brightnessLevels = try c.decodeIfPresent(MatrixBrightnessLevels.self, forKey: .brightnessLevels)
            ?? .legacy
        if let saved = try c.decodeIfPresent(MatrixColorStyles.self, forKey: .colorStyles) {
            colorStyles = saved
        } else if !fullColor {
            for state in MicState.allCases { colorStyles[state] = .solid }
        }
    }
}

enum MatrixColorCalibration {
    static func previewColor(_ color: RGB, style: MatrixColorStyle) -> RGB {
        guard !color.isOff else { return .off }
        if style == .artwork { return .green }
        let peak = Double(max(color.r, max(color.g, color.b)))
        func normalized(_ channel: UInt8) -> UInt8 {
            UInt8((Double(channel) * 255 / peak).rounded())
        }
        return RGB(r: normalized(color.r), g: normalized(color.g), b: normalized(color.b))
    }

    // Artwork and picked colors are display-encoded; LEDs need linear channel intensities.
    private static let linearChannels: [UInt8] = (0...255).map {
        UInt8((pow(Double($0) / 255, 2.2) * 255).rounded())
    }

    static func linearized(_ color: RGB) -> RGB {
        RGB(r: linearChannels[Int(color.r)], g: linearChannels[Int(color.g)],
            b: linearChannels[Int(color.b)])
    }
}

struct MatrixFrame: Equatable {
    static func status(state: MicState, color: RGB, brightness: Double, icons: MatrixIcons,
                       rotation: Int, mirrored: Bool, fullColor: Bool,
                       styles: MatrixColorStyles?, levels: MatrixBrightnessLevels,
                       animationTime: TimeInterval) -> MatrixFrame {
        let unavailable = state == .unknown
        return MatrixFrame(color: unavailable ? .green : color, brightness: brightness,
            rotation: rotation, icon: unavailable ? .warning : icons[state], mirrored: mirrored,
            fullColor: fullColor, style: unavailable ? .artwork : styles?[state],
            relativeBrightness: unavailable ? 1 : levels[state], animationTime: animationTime)
    }

    static let maxBrightness = 25
    static let maxLevel = 0.10
    static let defaultLevel = 0.09
    static let demoLevel = 0.05
    let color: RGB
    let brightness: Int
    let rotation: Int
    let bitmap: UInt64
    let mirrored: Bool
    let pixels: [RGB]
    let relativeBrightness: Double

    var outputPixels: [RGB] {
        pixels.map { MatrixColorCalibration.linearized($0).scaled(relativeBrightness) }
    }

    init(color: RGB, brightness: Double, rotation: Int, icon: MatrixIcon, mirrored: Bool = false,
         fullColor: Bool = true, style: MatrixColorStyle? = nil, relativeBrightness: Double = 1,
         animationTime: TimeInterval? = nil) {
        self.color = color
        let level = LightBrightness.clamped(brightness, maximum: Self.maxLevel)
        self.brightness = min(Self.maxBrightness, Int((level * 255).rounded()))
        self.rotation = max(0, min(3, rotation))
        let artwork = animationTime.map { icon.artwork(at: $0) } ?? icon.artwork
        let mask = icon.isAnimated ? artwork.enumerated().reduce(UInt64(0)) { result, entry in
            entry.element.isOff ? result : result | (UInt64(1) << (63 - entry.offset))
        } : icon.bitmap
        bitmap = mask
        self.mirrored = mirrored
        self.relativeBrightness = max(0, min(1, relativeBrightness))
        let gain = Double(max(color.r, max(color.g, color.b))) / 255
        let styledPixels: [RGB]
        switch style ?? (fullColor ? .artwork : .solid) {
        case .artwork:
            styledPixels = artwork.map { $0.scaled(gain) }
        case .tinted:
            styledPixels = artwork.map { pixel in
                RGB(r: UInt8(UInt16(pixel.r) * UInt16(color.r) / 255),
                    g: UInt8(UInt16(pixel.g) * UInt16(color.g) / 255),
                    b: UInt8(UInt16(pixel.b) * UInt16(color.b) / 255))
            }
        case .solid:
            styledPixels = (0..<64).map { index in
                mask & (UInt64(1) << (63 - index)) == 0 ? .off : color
            }
        }
        pixels = styledPixels
    }

    init(pixels: [RGB], brightness: Double, rotation: Int, mirrored: Bool) {
        precondition(pixels.count == 64, "Matrix frames require exactly 64 RGB pixels")
        color = .green
        bitmap = 0
        self.pixels = pixels
        relativeBrightness = 1
        self.brightness = min(Self.maxBrightness,
            Int((LightBrightness.clamped(brightness, maximum: Self.maxLevel) * 255).rounded()))
        self.rotation = max(0, min(3, rotation))
        self.mirrored = mirrored
    }

    func command(sequence: UInt32) -> Data {
        // Apply relative gain after gamma, bypassing the master PWM's nonzero floor.
        let rgb = outputPixels.map { String($0.hex.dropFirst()) }.joined()
        return Data("FRAME \(sequence) \(brightness) \(rotation + (mirrored ? 4 : 0)) \(rgb)\n".utf8)
    }
}

struct MatrixPreset: Equatable {
    let icon: MatrixIcon
    let style: MatrixColorStyle
    let color: RGB
    let brightness: Int
    let flags: Int
    let relative: Int
    let effect: LightEffect
    let rateMilliHz: Int
    let effectStart: TimeInterval
    let iconStart: TimeInterval

    func command(sequence: UInt32, now: TimeInterval,
                 wallTime: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Data {
        let styleID = style == .artwork ? 0 : style == .tinted ? 1 : 2
        let effectID = effect == .solid ? 0 : effect == .pulse ? 1 : 2
        func phase(_ elapsed: TimeInterval) -> UInt32 {
            UInt32(max(0, (elapsed * 1000).rounded(.down))
                .truncatingRemainder(dividingBy: Double(UInt32.max) + 1))
        }
        return Data(("PRESET \(sequence) \(icon.rawValue) \(styleID) \(color.hex.dropFirst()) " +
            "\(brightness) \(flags) \(relative) \(effectID) \(rateMilliHz) " +
            "\(phase(wallTime - effectStart)) \(phase(now - iconStart))\n").utf8)
    }
}

enum MatrixReply: Equatable {
    case hello
    case presets
    case acknowledged(UInt32)
    case timeout
    case error(String)

    init?(line: String) {
        if line == "MATRIX 4 8 8 25 PRESET1" { self = .presets; return }
        if line == "MATRIX 3 8 8 25" { self = .hello; return }
        if line.hasPrefix("MATRIX ") {
            self = .error("Unsupported MicMatrix handshake: \(line)")
            return
        }
        if line == "TIMEOUT" { self = .timeout; return }
        if line.hasPrefix("ERR ") { self = .error(String(line.dropFirst(4))); return }
        let parts = line.split(separator: " ")
        if parts.count == 2, parts[0] == "OK",
           parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" }),
           let sequence = UInt32(parts[1]) {
            self = .acknowledged(sequence)
            return
        }
        return nil
    }
}
