import Foundation

@main
enum MatrixTests {
    static func main() throws {
        testBrightnessCeilingForAllInputLevels()
        testExactWireFormatAndBounds()
        testReplyParsing()
        testPresetEncoding()
        testIconsAndStateSelection()
        try testLegacySettingsPreserveBusylightConfiguration()
        try testMatrixSettingsRoundTrip()
        try testMatrixV1SettingsMigration()
        testFullColorFrames()
        try testColorStyles()
        try testBrightnessFloorAndRainbow()
        try testRelativeStatusBrightness()
        testGammaCorrection()
        try testNewArtworkAndAnimations()
        testAutomaticDisplayBlanking()
        testMenuBarColors()
        try testFreshInstallDefaults()
        print("Seventeen Swift matrix protocol, artwork, brightness, and effects tests passed.")
    }

    static func testBrightnessCeilingForAllInputLevels() {
        for input in 0...1000 {
            let frame = MatrixFrame(color: .red, brightness: Double(input) / 100,
                                    rotation: 0, icon: .microphone)
            precondition((0...25).contains(frame.brightness))
        }
        precondition(MatrixFrame.maxLevel == 0.10)
        precondition(MatrixFrame.defaultLevel == 0.09 && MatrixFrame.demoLevel == 0.05)
        precondition(MatrixFrame(color: .red, brightness: 0.05, rotation: 0, icon: .dot).brightness == 13)
        precondition(MatrixFrame(color: .red, brightness: MatrixFrame.defaultLevel, rotation: 0, icon: .dot).brightness == 23)
        precondition(MatrixFrame(color: .red, brightness: MatrixFrame.demoLevel, rotation: 0, icon: .dot).brightness == 13)
        precondition(MatrixFrame(color: .red, brightness: 0.10, rotation: 0, icon: .dot).brightness == 25)
        for level in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            precondition(MatrixFrame(color: .red, brightness: level, rotation: 0, icon: .dot).brightness == 0)
        }
    }

    static func testExactWireFormatAndBounds() {
        let frame = MatrixFrame(color: RGB(r: 255, g: 130, b: 0), brightness: 1,
                                rotation: 20, icon: .dot, fullColor: false)
        let redPixels = (0..<64).map { index in
            MatrixIcon.dot.bitmap & (UInt64(1) << (63 - index)) == 0 ? "000000" : "FF3A00"
        }.joined()
        precondition(String(data: frame.command(sequence: 42), encoding: .utf8) ==
                     "FRAME 42 25 3 \(redPixels)\n")
        let reflected = MatrixFrame(color: .red, brightness: 1, rotation: 3, icon: .dot, mirrored: true, fullColor: false)
        let reflectedPixels = redPixels.replacingOccurrences(of: "FF3A00", with: "FF0000")
        precondition(String(data: reflected.command(sequence: 7), encoding: .utf8) ==
                     "FRAME 7 25 7 \(reflectedPixels)\n")
        precondition(MatrixFrame(color: .off, brightness: 0, rotation: -1, icon: .off).rotation == 0)
    }

    static func testReplyParsing() {
        precondition(MatrixReply(line: "MATRIX 4 8 8 25 PRESET1") == .presets)
        precondition(MatrixReply(line: "MATRIX 3 8 8 25") == .hello)
        precondition(MatrixReply(line: "OK 4294967295") == .acknowledged(UInt32.max))
        precondition(MatrixReply(line: "ERR command") == .error("command"))
        precondition(MatrixReply(line: "TIMEOUT") == .timeout)
        for line in ["MATRIX 3 8 8 12", "MATRIX 2 8 8 12", "MATRIX 1 8 8 63", "MATRIX 2 8 8 5", "MATRIX 2 8 8 25", "MATRIX 2 8 8 255", "OK -1", "OK +1",
                     "OK 4294967296", "OK 1 extra", "boot diagnostics"] {
            precondition(MatrixReply(line: line) == nil)
        }

    }

    static func testPresetEncoding() {
        let preset = MatrixPreset(icon: .shrug, style: .tinted, color: RGB(r: 255, g: 128, b: 0),
            brightness: 13, flags: 7, relative: 7500, effect: .pulse, rateMilliHz: 250,
            effectStart: 10, iconStart: 20)
        precondition(String(decoding: preset.command(sequence: 42, now: 22, wallTime: 11),
            as: UTF8.self) == "PRESET 42 shrug 1 FF8000 13 7 7500 1 250 1000 2000\n")
    }

    static func testIconsAndStateSelection() {
        var icons = MatrixIcons()
        precondition(icons[.unmuted] == .dot)
        precondition(icons[.muted] == .mutedMicrophone)
        icons[.unmuted] = .fire
        precondition(icons.unmuted == .fire)
        precondition(MatrixIcon.off.bitmap == 0)
        for icon in MatrixIcon.allCases where icon != .off {
            precondition((1...64).contains(icon.bitmap.nonzeroBitCount))
            precondition(icon.artwork.count == 64)
            precondition(Set(icon.artwork.filter { !$0.isOff }).count >= 2)
        }
        precondition(Set(MatrixIcon.allCases.map(\.bitmap)).count == MatrixIcon.allCases.count)
    }

    static func testLegacySettingsPreserveBusylightConfiguration() throws {
        var original = AppSettings()
        original.kuando.enabled = false
        original.kuando.brightness = 0.42
        original.kuando.deviceSerial = "existing-busylight"
        original.blinkStick.enabled = true
        original.rainbowDuration = 2.5
        let encoded = try JSONEncoder().encode(original)
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            preconditionFailure("Settings must encode as an object")
        }
        object.removeValue(forKey: "matrix")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        precondition(decoded == original)
        precondition(!decoded.matrix.light.enabled)
        precondition(decoded.matrix.light.brightness == MatrixFrame.defaultLevel)
    }

    static func testMatrixSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.matrix.light.enabled = true
        settings.matrix.light.deviceSerial = "matrix-serial"
        settings.matrix.icons.unmuted = .fire
        settings.matrix.rotation = 2
        settings.matrix.mirrored = true
        settings.matrix.fullColor = false
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        precondition(decoded == settings)
    }

    static func testMatrixV1SettingsMigration() throws {
        var configuration = MatrixConfig()
        configuration.light.enabled = true
        configuration.light.brightness = 0.20
        configuration.light.deviceSerial = "existing-matrix"
        configuration.rotation = 2
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any] else {
            preconditionFailure("Matrix settings must encode as an object")
        }
        object.removeValue(forKey: "mirrored")
        object.removeValue(forKey: "fullColor")
        let decoded = try JSONDecoder().decode(MatrixConfig.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(decoded.light.enabled && decoded.light.deviceSerial == "existing-matrix")
        precondition(decoded.light.brightness == MatrixFrame.maxLevel)
        precondition(decoded.rotation == 2 && !decoded.mirrored)
        precondition(decoded.fullColor)
        configuration.light.brightness = 5.0 / 255
        let preserved = try JSONDecoder().decode(MatrixConfig.self, from: JSONEncoder().encode(configuration))
        precondition(preserved.light.brightness == configuration.light.brightness)
    }

    static func testFullColorFrames() {
        for icon in MatrixIcon.allCases {
            let frame = MatrixFrame(color: .red, brightness: 0.02, rotation: 0, icon: icon)
            precondition(frame.pixels == icon.artwork)
            let parts = String(decoding: frame.command(sequence: UInt32.max), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            precondition(parts.count == 5 && parts[0] == "FRAME" && parts[4].count == 384)
            precondition(frame.command(sequence: UInt32.max).count <= 448)
            let dark = MatrixFrame(color: .off, brightness: 0.02, rotation: 0, icon: icon)
            precondition(dark.pixels.allSatisfy(\.isOff))
            let half = MatrixFrame(color: RGB(r: 128, g: 0, b: 0), brightness: 0.02, rotation: 0, icon: icon)
            precondition(half.pixels == icon.artwork.map { $0.scaled(128.0 / 255) })
        }
    }

    static func testColorStyles() throws {
        let tint = RGB(r: 128, g: 255, b: 0)
        let frame = MatrixFrame(color: tint, brightness: 0.02, rotation: 0,
                                icon: .microphone, style: .tinted)
        precondition(frame.pixels == MatrixIcon.microphone.artwork.map {
            RGB(r: UInt8(UInt16($0.r) * 128 / 255), g: $0.g, b: 0)
        })
        for style in MatrixColorStyle.allCases {
            let dark = MatrixFrame(color: .off, brightness: 0.02, rotation: 0, icon: .dot, style: style)
            precondition(dark.pixels.allSatisfy(\.isOff))
        }
        precondition(MatrixIcon.dot.artwork.filter { !$0.isOff }.allSatisfy { $0.r > $0.g && $0.r > $0.b })
        var config = MatrixConfig()
        config.fullColor = false
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any] else {
            preconditionFailure("Matrix settings must encode as an object")
        }
        object.removeValue(forKey: "colorStyles")
        let legacy = try JSONDecoder().decode(MatrixConfig.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(MicState.allCases.allSatisfy { legacy.colorStyles[$0] == .solid })
        config.colorStyles[.muted] = .tinted
        config.colorStyles[.unmuted] = .solid
        let decoded = try JSONDecoder().decode(MatrixConfig.self, from: JSONEncoder().encode(config))
        precondition(decoded == config)
    }

    static func testBrightnessFloorAndRainbow() throws {
        for value in [0.0001, 0.005, 0.009, 0.01] {
            precondition(LightBrightness.clamped(value) == 0.01)
            precondition(MatrixFrame(color: .red, brightness: value, rotation: 0, icon: .dot).brightness == 3)
        }
        precondition(LightBrightness.clamped(0) == 0)
        var config = OutputConfig(enabled: true, colors: .muteLight)
        config.brightness = 0.005
        let decoded = try JSONDecoder().decode(OutputConfig.self, from: JSONEncoder().encode(config))
        precondition(decoded.brightness == 0.01)
        let first = Effects.matrixRainbow(t: 0, duration: 1.5, sweeps: 2)
        precondition(first.count == 64 && first.allSatisfy { !$0.isOff })
        precondition(Set(first).count > 20)
        precondition(first != Effects.matrixRainbow(t: 0.2, duration: 1.5, sweeps: 2))
        precondition(Effects.matrixRainbow(t: -1, duration: 1.5, sweeps: 2).allSatisfy(\.isOff))
        for step in 0...100 {
            let pixels = Effects.matrixRainbow(t: Double(step) / 100 * 1.5, duration: 1.5, sweeps: 2)
            let frame = MatrixFrame(pixels: pixels, brightness: 0.005, rotation: 2, mirrored: true)
            precondition(frame.pixels == pixels && frame.brightness == 3 && frame.rotation == 2 && frame.mirrored)
            precondition(frame.command(sequence: UInt32(step)).count <= 448)
        }
    }

    static func testRelativeStatusBrightness() throws {
        var config = MatrixConfig()
        precondition(config.brightnessLevels.muted == 0.75 && config.brightnessLevels.notInMeeting == 0.20)
        config.brightnessLevels[.muted] = 0.5
        config.brightnessLevels[.notInMeeting] = 0.25
        config.brightnessLevels[.unknown] = 0
        precondition(config.brightnessLevels[.unmuted] == 1)
        let roundTrip = try JSONDecoder().decode(MatrixConfig.self, from: JSONEncoder().encode(config))
        precondition(roundTrip == config)
        var settings = AppSettings()
        settings.matrix = config
        let savedSettings = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        precondition(savedSettings == settings)
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) as? [String: Any] else {
            preconditionFailure("Matrix settings must encode as an object")
        }
        object.removeValue(forKey: "brightnessLevels")
        let legacy = try JSONDecoder().decode(MatrixConfig.self, from: JSONSerialization.data(withJSONObject: object))
        precondition(MicState.allCases.allSatisfy { legacy.brightnessLevels[$0] == 1 })
        let partial = try JSONDecoder().decode(MatrixBrightnessLevels.self,
            from: Data(#"{"muted":0.5,"unknown":-1,"notInMeeting":2}"#.utf8))
        precondition(partial.muted == 0.5 && partial.unmuted == 1
            && partial.unknown == 0 && partial.notInMeeting == 1)

        for style in MatrixColorStyle.allCases {
            for icon in MatrixIcon.allCases {
                for master in [0.0, 0.01, 0.02, 0.10, 1.0] {
                    let full = MatrixFrame(color: .red, brightness: master, rotation: 2,
                        icon: icon, mirrored: true, style: style)
                    for relative in [0.0, 0.25, 0.5, 1.0, 2.0, -1.0] {
                        let frame = MatrixFrame(color: .red, brightness: master, rotation: 2,
                            icon: icon, mirrored: true, style: style, relativeBrightness: relative)
                        precondition(frame.brightness == full.brightness)
                        precondition(frame.pixels == full.pixels)
                        precondition(frame.outputPixels == full.outputPixels.map { $0.scaled(relative) })
                        precondition(frame.rotation == full.rotation && frame.mirrored == full.mirrored)
                        if relative == 0 { precondition(frame.outputPixels.allSatisfy(\.isOff)) }
                    }
                }
            }
        }
        let dim = MatrixFrame(color: .red, brightness: 0.01, rotation: 0,
            icon: .dot, style: .solid, relativeBrightness: 0.5)
        let physicalRed = Int(dim.outputPixels.map(\.r).max()!) * dim.brightness / 255
        precondition(physicalRed == 1, "Relative dimming must allow output below the master's 3/255 floor")
    }

    static func testGammaCorrection() {
        precondition(MatrixColorCalibration.linearized(.off) == .off)
        for color in [RGB.red, .green, .blue, RGB(r: 255, g: 255, b: 255)] {
            precondition(MatrixColorCalibration.linearized(color) == color)
        }
        var previous: UInt8 = 0
        for value in 0...255 {
            let channel = UInt8(value)
            let corrected = MatrixColorCalibration.linearized(RGB(r: channel, g: channel, b: channel))
            precondition(corrected.r == corrected.g && corrected.g == corrected.b)
            precondition(corrected.r <= channel && corrected.r >= previous)
            previous = corrected.r
        }
        let red = RGB(r: 255, g: 35, b: 45)
        precondition(MatrixColorCalibration.linearized(red) == RGB(r: 255, g: 3, b: 6))
        var priorRed = 0
        for master in [0.02, 0.03, 0.05, 0.10] {
            let frame = MatrixFrame(color: red, brightness: master, rotation: 0, icon: .heart, style: .solid)
            for pixel in frame.outputPixels where !pixel.isOff {
                precondition(Int(pixel.g) * frame.brightness / 255 == 0)
                precondition(Int(pixel.b) * frame.brightness / 255 == 0)
                precondition(Int(pixel.r) * frame.brightness / 255 >= priorRed)
            }
            priorRed = frame.brightness
        }
        let artwork = MatrixFrame(color: .red, brightness: 0.10, rotation: 0, icon: .heart)
        precondition(artwork.pixels == MatrixIcon.heart.artwork, "Keep pink and cream source artwork")
        let rainbow = Effects.matrixRainbow(t: 0.2, duration: 1.5, sweeps: 2)
        let frame = MatrixFrame(pixels: rainbow, brightness: 0.02, rotation: 0, mirrored: false)
        precondition(frame.outputPixels == rainbow.map { MatrixColorCalibration.linearized($0) })
        let half = MatrixFrame(color: .red, brightness: 0.02, rotation: 0, icon: .heart,
            relativeBrightness: 0.5)
        precondition(half.outputPixels == artwork.outputPixels.map { $0.scaled(0.5) })
        let parts = String(decoding: half.command(sequence: 1), as: UTF8.self).split(separator: " ")
        precondition(parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
            == half.outputPixels.map { String($0.hex.dropFirst()) }.joined())
    }

    static func testAutomaticDisplayBlanking() {
        for flags in 0..<16 {
            let availability = MatrixDisplayAvailability(locked: flags & 1 != 0,
                sessionInactive: flags & 2 != 0, displayAsleep: flags & 4 != 0,
                systemAsleep: flags & 8 != 0)
            for state in MicState.allCases {
                let inCall = state == .muted || state == .unmuted
                precondition(availability.shouldBlank(state: state) == (!inCall && flags != 0))
            }
        }
        var availability = MatrixDisplayAvailability()
        availability.locked = true
        availability.displayAsleep = true
        availability.displayAsleep = false
        precondition(availability.shouldBlank(state: .notInMeeting), "Screen wake must not bypass lock")
        availability.locked = false
        precondition(!availability.shouldBlank(state: .notInMeeting))
        availability.systemAsleep = true
        precondition(availability.shouldBlank(state: .unknown))
        availability.systemAsleep = false
        precondition(!availability.shouldBlank(state: .unknown))
    }

    static func testMenuBarColors() {
        let white = RGB(r: 255, g: 255, b: 255)
        for state in MicState.allCases {
            precondition(Effects.menuBarColor(state: state, paused: true, time: 0) == white)
        }
        for time in [0.0, 0.375, 0.75, 1.5] {
            precondition(Effects.menuBarColor(state: .muted, paused: false, time: time) == .green)
            for state in [MicState.unknown, .notInMeeting] {
                precondition(Effects.menuBarColor(state: state, paused: false, time: time) == white)
            }
            let live = Effects.menuBarColor(state: .unmuted, paused: false, time: time)
            precondition(live.g == 0 && live.b == 0 && live.r >= 114)
        }
        precondition(Effects.menuBarColor(state: .unmuted, paused: false, time: 0) == .red)
        precondition(Effects.menuBarColor(state: .unmuted, paused: false, time: 0.75) != .red)
        precondition(Effects.menuBarColor(state: .unmuted, paused: false, time: 1.5) == .red)
    }

    static func testFreshInstallDefaults() throws {
        let fresh = AppSettings()
        precondition(fresh.matrix.light.brightness == 0.09 && !fresh.matrix.light.enabled)
        for (state, icon, level) in [(MicState.unmuted, MatrixIcon.dot, 1.0),
                                    (.muted, .mutedMicrophone, 0.75), (.notInMeeting, .shield, 0.20)] {
            precondition(fresh.matrix.icons[state] == icon)
            precondition(fresh.matrix.brightnessLevels[state] == level)
            precondition(fresh.matrix.colorStyles[state] == .artwork)
            let frame = MatrixFrame.status(state: state, color: fresh.matrix.light.colors[state],
                brightness: fresh.matrix.light.brightness, icons: fresh.matrix.icons,
                rotation: 0, mirrored: false, fullColor: fresh.matrix.fullColor,
                styles: fresh.matrix.colorStyles, levels: fresh.matrix.brightnessLevels, animationTime: 0)
            precondition(frame.pixels == icon.artwork, "Fresh installs must use the full palette without hidden color gain")
            precondition(frame.brightness == 23 && frame.relativeBrightness == level)
        }
        precondition(fresh.effects.unmuted.effect == .pulse && fresh.effects.unmuted.rateHz == 1)
        precondition(fresh.effects.muted.effect == .solid && fresh.effects.notInMeeting.effect == .solid)
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(fresh))
        precondition(roundTrip == fresh)
        var saved = fresh
        saved.matrix.light.brightness = 0.02
        saved.matrix.light.colors = .muteLight
        saved.matrix.icons.unmuted = .microphone
        saved.matrix.icons.notInMeeting = .dot
        saved.matrix.brightnessLevels = .legacy
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(saved))
        precondition(restored == saved, "Do not apply new defaults over existing settings")
    }

    static func testNewArtworkAndAnimations() throws {
        precondition(MatrixIcon.allCases.count == 16)
        precondition(!MatrixIcon.allCases.contains(.off) && MatrixIcon.allCases.contains(.warning))
        precondition(MatrixIcon.warning.artwork[3] == RGB(r: 255, g: 210, b: 20))
        precondition(MatrixIcon.warning.artwork[11] == RGB(r: 255, g: 35, b: 45))
        precondition(MatrixIcon.warning.artwork[51] == RGB(r: 255, g: 210, b: 20))
        precondition(MatrixIcon.warning.artwork[59] == RGB(r: 255, g: 35, b: 45))
        for row in 0..<5 {
            let pixels = Array(MatrixIcon.warning.artwork[(row * 8)..<(row * 8 + 8)])
            precondition(pixels.filter { !$0.isOff }.count == 2)
            precondition(!pixels[3].isOff && !pixels[4].isOff)
        }
        precondition(MatrixIcon(rawValue: "off") == .off)
        var legacyIcons = MatrixIcons()
        legacyIcons.unknown = .off
        var legacyLevels = MatrixBrightnessLevels()
        legacyLevels.unknown = 0
        let warning = MatrixFrame.status(state: .unknown, color: .off, brightness: 0.02,
            icons: legacyIcons, rotation: 2, mirrored: true, fullColor: false,
            styles: MatrixColorStyles(), levels: legacyLevels, animationTime: 0)
        precondition(warning.pixels == MatrixIcon.warning.artwork && warning.relativeBrightness == 1)
        precondition(warning.brightness == 5 && warning.rotation == 2 && warning.mirrored)
        precondition(warning.outputPixels.contains { !$0.isOff })
        precondition(MatrixIcon.shield.label == "Adobe A")
        precondition(MatrixIcon(rawValue: "shield") == .shield)
        let adobe = MatrixIcon.shield.artwork
        precondition(adobe.count == 64 && adobe.contains(.off))
        precondition(adobe.contains(RGB(r: 250, g: 15, b: 0)))
        precondition(adobe.filter { !$0.isOff }.allSatisfy { $0.r >= 120 && $0.g <= 15 && $0.b == 0 })
        precondition(adobe[1 * 8 + 2].r == 120 && adobe[2 * 8 + 2].r == 210)
        precondition(adobe[0 * 8 + 3].r == 210 && adobe[1 * 8 + 3].r == 250)
        for style in MatrixColorStyle.allCases {
            precondition(MatrixColorCalibration.previewColor(.off, style: style) == .off)
            let normalized = MatrixColorCalibration.previewColor(.dimGreen, style: style)
            precondition(max(normalized.r, max(normalized.g, normalized.b)) == 255)
        }
        precondition(MatrixColorCalibration.previewColor(.dimGreen, style: .artwork)
            == MatrixColorCalibration.previewColor(.red, style: .artwork))
        precondition(MatrixColorCalibration.previewColor(RGB(r: 40, g: 20, b: 0), style: .tinted)
            == RGB(r: 255, g: 128, b: 0))
        precondition(adobe[4 * 8 + 3].isOff && adobe[4 * 8 + 4].isOff)
        precondition(adobe[5 * 8 + 3].isOff && adobe[5 * 8 + 4].isOff)
        precondition(adobe[6 * 8 + 4].isOff && adobe[7 * 8 + 5].isOff)
        for row in 0..<6 {
            precondition(Array(adobe[(row * 8)..<(row * 8 + 8)])
                == Array(adobe[(row * 8)..<(row * 8 + 8)].reversed()),
                "The upper silhouette and legs should be symmetric")
        }
        let muted = MatrixIcon.mutedMicrophone.artwork
        let slash = RGB(r: 255, g: 35, b: 45)
        let live = MatrixIcon.microphone.artwork
        precondition(!live.contains(RGB(r: 0, g: 210, b: 255)))
        precondition(!live.contains(RGB(r: 255, g: 210, b: 20)))
        precondition(live.contains(slash) && live.contains(RGB(r: 145, g: 12, b: 25)))
        for i in [0, 1, 6, 7] {
            precondition(live[i * 9].isOff, "Live microphone must not have a diagonal slash")
        }
        for row in 4...5 {
            let armRow = Array(live[(row * 8)..<(row * 8 + 8)])
            precondition(armRow == Array(armRow.reversed()), "Live microphone arms must be symmetric")
        }
        for index in 0..<64 where index / 8 != index % 8 && index / 8 != 4 && index / 8 != 5 {
            if muted[index] == RGB(r: 35, g: 255, b: 95) {
                precondition(live[index] == slash, "Live red pixels must match the muted green layout")
            }
        }
        for i in 0..<8 { precondition(muted[i * 9] == slash) }
        precondition(!muted.contains(RGB(r: 0, g: 210, b: 255)))
        precondition(!muted.contains(RGB(r: 25, g: 65, b: 200)))
        precondition(muted.contains(RGB(r: 35, g: 255, b: 95)))
        precondition(MatrixIcon.prohibited.artwork.filter { !$0.isOff }.allSatisfy { $0.r > $0.g && $0.r > $0.b })
        precondition(MatrixIcon.prohibited.artwork[2 * 8 + 1].isOff)
        precondition(MatrixIcon.smiley.artwork[2 * 8 + 2].isOff)
        precondition(MatrixIcon.smiley.artwork[2 * 8 + 5].isOff)
        precondition(MatrixIcon.smiley.artwork[6 * 8 + 3].isOff)
        precondition(Set([MatrixIcon.afk.artwork(at: 0), MatrixIcon.afk.artwork(at: 0.8),
            MatrixIcon.afk.artwork(at: 1.6)]).count == 3)
        precondition(MatrixIcon.afk.artwork(at: 0) == MatrixIcon.afk.artwork(at: 2.4 + 0.001))
        let width = MatrixIconAnimation.shrugWidth
        let first = MatrixIcon.shrug.artwork(at: MatrixIconAnimation.shrugPreviewTime)
        let shifted = MatrixIcon.shrug.artwork(at: MatrixIconAnimation.shrugPreviewTime + 0.125)
        for row in 0..<8 {
            for column in 0..<7 {
                precondition(shifted[row * 8 + column] == first[row * 8 + column + 1],
                    "Shrug must travel right to left, not mirror or reverse its glyphs")
            }
        }
        precondition(MatrixIcon.shrug.artwork(at: 0)
            == MatrixIcon.shrug.artwork(at: Double(width + 8) / 8))
        precondition(MatrixIconAnimation.shrugGlyphs.count == 9)
        var settings = AppSettings()
        settings.matrix.icons.unmuted = .afk
        settings.matrix.icons.muted = .smiley
        settings.matrix.icons.notInMeeting = .shrug
        let saved = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        precondition(saved == settings)
        for icon in [MatrixIcon.afk, .shrug] {
            var frames = Set<Data>()
            for tick in 0...120 {
                let time = Double(tick) / 8
                let artwork = icon.artwork(at: time)
                precondition(artwork.count == 64)
                for style in MatrixColorStyle.allCases {
                    let frame = MatrixFrame(color: .red, brightness: 0.10, rotation: 3,
                        icon: icon, mirrored: true, style: style, relativeBrightness: 0.5,
                        animationTime: time)
                    precondition(frame.bitmap.nonzeroBitCount == artwork.filter { !$0.isOff }.count)
                    precondition(frame.brightness == 25 && frame.rotation == 3 && frame.mirrored)
                    precondition(frame.relativeBrightness == 0.5 && frame.command(sequence: 1).count <= 448)
                    if style == .solid {
                        precondition(frame.pixels == artwork.map { $0.isOff ? .off : .red })
                    }
                    frames.insert(frame.command(sequence: 1))
                }
            }
            precondition(frames.count > 3)
        }
    }

}
