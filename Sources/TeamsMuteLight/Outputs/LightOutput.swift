import Foundation

/// Anything that can show a color for a mic state. All calls happen on the main thread.
protocol LightOutput: AnyObject {
    var name: String { get }
    /// Short human-readable status for the Settings UI.
    var statusText: String { get }
    /// Show `color` (already chosen for `state`) at `brightness` 0...1.
    func apply(state: MicState, color: RGB, brightness: Double)
    /// Stop driving the light (turn off / stop keep-alives) so other software can use it.
    func release()
    /// True for local USB lights that can take ~25 updates/s (pulse, flash, rainbow).
    /// Network lights only receive the solid state color.
    var supportsAnimation: Bool { get }
}
