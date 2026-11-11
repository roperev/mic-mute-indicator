import AppKit
import SwiftUI

@main
struct SettingsWindowTests: App {
    @StateObject private var controller = AppController(measurementSettings: AppSettings())

    var body: some Scene {
        WindowGroup {
            SettingsLauncher()
        }
        Settings {
            SettingsView()
                .environmentObject(controller)
                .background(SettingsSizeProbe())
        }
    }
}

private struct SettingsLauncher: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Testing taller SwiftUI Settings")
            .onAppear {
                DispatchQueue.main.async { openSettings() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    fputs("Settings window test timed out.\n", stderr)
                    exit(1)
                }
            }
    }
}

private struct SettingsSizeProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private var scheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, let window = self.window, window.isVisible else {
                    fputs("SwiftUI Settings window did not appear.\n", stderr)
                    exit(1)
                }
                precondition(abs(bounds.width - 760) < 1, "Settings width changed")
                precondition(abs(bounds.height - 1030) < 1, "Settings must be 350 points taller")
                print("SwiftUI-managed Settings displays fixed 760 x 1030 content.")
                window.close()
                exit(0)
            }
        }
    }
}
