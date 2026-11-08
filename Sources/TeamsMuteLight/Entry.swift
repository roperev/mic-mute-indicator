import AppKit
import SwiftUI

/// Single binary, two modes:
///   TeamsMuteLight                -> menu bar app
///   TeamsMuteLight --cli <cmd>    -> command-line tools for testing hardware / detection
@main
enum Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--cli") {
            CLI.run(Array(args[(i + 1)...]))
        } else {
            TeamsMuteLightApp.main()
        }
    }
}

struct TeamsMuteLightApp: App {
    @StateObject private var controller = AppController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
        } label: {
            MenuBarStatusIcon(controller: controller)
        }

        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}

private struct MenuBarStatusIcon: View {
    @ObservedObject var controller: AppController

    var body: some View {
        icon(at: controller.menuBarPulseTime)
    }

    private func icon(at time: TimeInterval) -> some View {
        let rgb = Effects.menuBarColor(state: controller.micState, paused: controller.paused, time: time)
        let tint = NSColor(srgbRed: Double(rgb.r) / 255, green: Double(rgb.g) / 255,
            blue: Double(rgb.b) / 255, alpha: 1)
        let symbol = NSImage(systemSymbolName: controller.menuBarSymbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "lightbulb", accessibilityDescription: nil)!
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            tint.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        // Menu-bar template images discard color, so bake the tint into a non-template image.
        image.isTemplate = false
        return Image(nsImage: image)
            .accessibilityLabel(controller.statusHeadline)
    }
}
