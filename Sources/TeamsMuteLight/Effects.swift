import Foundation

/// Pure functions for software light effects (rendered ~25 fps by AppController).
enum Effects {
    static let frameInterval: TimeInterval = 1.0 / 25.0

    /// Brightness multiplier 0...1 for `effect` at `t` seconds into the state.
    static func level(_ effect: LightEffect, rateHz: Double, t: TimeInterval) -> Double {
        let rate = max(0.1, min(10, rateHz))
        switch effect {
        case .solid:
            return 1
        case .pulse:
            // Starts dim and rests low; each cycle swings up to a short, bright peak.
            // Cubing the cosine wave narrows the peak: brighter than half only ~30% of
            // the cycle, near the floor most of the rest. The floor keeps it from going dark.
            let x = 0.5 - 0.5 * cos(2 * .pi * rate * t)
            return 0.06 + 0.94 * x * x * x
        case .flash:
            let phase = (rate * t).truncatingRemainder(dividingBy: 1)
            return phase < 0.5 ? 1 : 0
        }
    }

    /// Where each sweep starts/ends on the color wheel: 0 = red, 1/3 = green, 2/3 = blue.
    static let rainbowStartHue: Double = 0
    /// Fraction of each sweep spent holding the start color, split evenly between the start and end.
    static let rainbowHoldFraction: Double = 0.16

    /// `sweeps` full hue sweeps across `duration` seconds. Each sweep holds the start color
    /// briefly at both ends, so it clearly begins and finishes on that color.
    static func rainbow(t: TimeInterval, duration: TimeInterval, sweeps: Int) -> RGB {
        let d = max(0.2, duration)
        let n = Double(max(1, sweeps))
        let progress = max(0, min(0.999_999, t / d)) * n    // 0..<n
        let local = progress.truncatingRemainder(dividingBy: 1)  // 0..<1 within this sweep
        let hold = rainbowHoldFraction / 2
        let sweep = max(0, min(1, (local - hold) / (1 - 2 * hold)))
        let hue = (rainbowStartHue + sweep).truncatingRemainder(dividingBy: 1)
        return hsv(hue, 1, 1, gamma: 2.2)
    }

    /// HSV -> RGB. `gamma` > 1 corrects for linear LED PWM vs. the eye's non-linear response,
    /// so blends look evenly spaced (otherwise a dash of green turns red orange almost instantly,
    /// and fading blue keeps "magenta" lingering until the very end).
    static func hsv(_ h: Double, _ s: Double, _ v: Double, gamma: Double = 1) -> RGB {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), w = v * (1 - (1 - f) * s)
        var r = v, g = p, b = q
        switch i {
        case 0: r = v; g = w; b = p
        case 1: r = q; g = v; b = p
        case 2: r = p; g = v; b = w
        case 3: r = p; g = q; b = v
        case 4: r = w; g = p; b = v
        default: r = v; g = p; b = q
        }
        func c(_ x: Double) -> UInt8 { UInt8(max(0, min(255, (pow(max(0, x), gamma) * 255).rounded()))) }
        return RGB(r: c(r), g: c(g), b: c(b))
    }
}
