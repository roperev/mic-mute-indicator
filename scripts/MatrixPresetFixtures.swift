import Foundation

@main
enum MatrixPresetFixtures {
    static func main() {
        let colors: [RGB] = [.green, RGB(r: 190, g: 85, b: 240)]
        for icon in MatrixIcon.allCases + [.off] {
            for style in MatrixColorStyle.allCases {
                for effect in [LightEffect.solid, .pulse, .flash] {
                    for rate in [0.25, 1.0, 10.0] {
                        for milliseconds in [0, 49, 125, 501, 801, 1601, 2999, 6251] {
                            for color in colors {
                                let t = Double(milliseconds) / 1000
                                let preset = MatrixPreset(icon: icon, style: style, color: color,
                                    brightness: 13, flags: 7, relative: 7500, effect: effect,
                                    rateMilliHz: Int(rate * 1000), effectStart: 0, iconStart: 0)
                                let frame = MatrixFrame(color: color.scaled(Effects.level(effect,
                                    rateHz: rate, t: t)), brightness: 0.05, rotation: 3, icon: icon,
                                    mirrored: true, style: style, relativeBrightness: 0.75, animationTime: t)
                                print(String(decoding: preset.command(sequence: 1, now: t, wallTime: t),
                                    as: UTF8.self).trimmingCharacters(in: .newlines))
                                print(frame.outputPixels.map { String($0.hex.dropFirst()) }.joined())
                            }
                        }
                    }
                }
            }
        }
    }
}
