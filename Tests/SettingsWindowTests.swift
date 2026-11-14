import AppKit
import SwiftUI

@main
struct SettingsWindowTests: App {
    @StateObject private var fixture = SettingsFixture()

    var body: some Scene {
        WindowGroup {
            SettingsLauncher()
        }
        Settings {
            SettingsView(selectedTab: $fixture.tab,
                expandAdvancedDetails: !CommandLine.arguments.contains("--screenshots"))
                .environmentObject(fixture.controller)
                .preferredColorScheme(CommandLine.arguments.contains("--light") ? .light : .dark)
                .background(SettingsSizeProbe(fixture: fixture))
        }
    }
}

private struct SettingsLauncher: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text("Testing Settings")
            .onAppear {
                DispatchQueue.main.async { openSettings() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    fputs("Settings window test timed out.\n", stderr)
                    exit(1)
                }
            }
    }
}

private final class SettingsFixture: ObservableObject {
    @Published var tab = 0
    let controller: AppController
    let initialSettings: AppSettings

    init() {
        Self.testColorEntry()
        var settings = AppSettings()
        precondition(settings.callStartRainbow)
        settings.matrix.light.enabled = true
        if CommandLine.arguments.contains("--screenshots") {
            settings.kuando.enabled = false
        } else {
            settings.callStartRainbow = false
            settings.blinkStick.enabled = true
            settings.homeAssistant.light.enabled = true
            settings.webhook.light.enabled = true
            settings.matrix.colorStyles.muted = .tinted
            settings.matrix.colorStyles.notInMeeting = .solid
            settings.matrix.light.colors.notInMeeting = .off
            settings.axPollInterval = 0.7
            settings.effects.muted = StateEffect(effect: .flash, rateHz: 2)
        }
        initialSettings = settings
        controller = AppController(measurementSettings: settings)
    }

    static func testColorEntry() {
        var color = RGB.green
        for invalid in ["", "#", "#FFF", "FF000", "#FF00000", "#GG0000", "off", "#12 345"] {
            var entry = HexColorEntry(color: color)
            entry.text = invalid
            precondition(!entry.apply(to: &color) && entry.error != nil && color == .green)
        }
        var entry = HexColorEntry(color: color)
        entry.text = "  ff8000\n"
        precondition(entry.apply(to: &color) && entry.text == "#FF8000" && entry.error == nil)
        precondition(color == RGB(r: 255, g: 128, b: 0))
        entry.text = "#000000"
        precondition(entry.apply(to: &color) && color.isOff)
        entry.text = "#abcdef"
        precondition(entry.apply(to: &color) && entry.text == "#ABCDEF")
        entry.text = "#bad"
        precondition(!entry.apply(to: &color) && color.hex == "#ABCDEF")
        entry.text = "#FFFFFF"
        precondition(entry.apply(to: &color) && entry.error == nil)
        print("Custom hex entry validates before commit, preserves values on error, and supports off.")
    }
}

private struct SettingsSizeProbe: NSViewRepresentable {
    let fixture: SettingsFixture

    func makeNSView(context: Context) -> Probe { Probe(fixture: fixture) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        let fixture: SettingsFixture
        private var scheduled = false

        init(fixture: SettingsFixture) {
            self.fixture = fixture
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("Test probe is created programmatically") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !scheduled else { return }
            scheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.inspect(tab: 0) }
        }

        private func inspect(tab: Int) {
            fixture.tab = tab
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard let window = self.window, let content = window.contentView, window.isVisible else {
                    fputs("SwiftUI Settings did not appear.\n", stderr)
                    exit(1)
                }
                precondition(abs(self.bounds.width - 760) < 1 && abs(self.bounds.height - 1030) < 1)
                self.capture(content, name: "tab-\(tab)")
                if tab == 1 && !CommandLine.arguments.contains("--screenshots") {
                    self.inspectLowerLights(content)
                } else if tab < 3 {
                    self.inspect(tab: tab + 1)
                } else {
                    self.inspectColorPopover()
                }
            }
        }

        private func inspectLowerLights(_ content: NSView) {
            guard let scroll = scrollView(in: content), let document = scroll.documentView else {
                fputs("Lights form did not expose a scrollable document.\n", stderr)
                exit(1)
            }
            let original = scroll.contentView.bounds.origin
            let bottom = document.isFlipped
                ? max(0, document.bounds.height - scroll.contentView.bounds.height) : 0
            scroll.contentView.scroll(to: NSPoint(x: original.x, y: bottom))
            scroll.reflectScrolledClipView(scroll.contentView)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.capture(content, name: "lights-network-outputs")
                scroll.contentView.scroll(to: original)
                scroll.reflectScrolledClipView(scroll.contentView)
                self.inspect(tab: 2)
            }
        }

        private func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, !view.isHiddenOrHasHiddenAncestor,
               let document = scroll.documentView,
               document.bounds.height > scroll.contentView.bounds.height + 100 {
                return scroll
            }
            return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
        }

        private func inspectColorPopover() {
            guard let content = window?.contentView else { exit(1) }
            let popover = NSPopover()
            popover.contentViewController = NSHostingController(rootView:
                ColorSwatchChooser(selection: Binding(
                    get: { self.fixture.controller.settings.matrix.light.colors.muted },
                    set: { self.fixture.controller.settings.matrix.light.colors.muted = $0 }),
                    dismiss: { popover.close() })
                .preferredColorScheme(CommandLine.arguments.contains("--light") ? .light : .dark))
            popover.show(relativeTo: NSRect(x: 150, y: 450, width: 10, height: 10),
                of: content, preferredEdge: .maxX)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                precondition(popover.isShown)
                self.capture(popover.contentViewController!.view, name: "color-popover")
                popover.close()
                self.finish()
            }
        }

        private func capture(_ view: NSView, name: String) {
            guard CommandLine.arguments.contains("--capture") else { return }
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fputs("Could not capture Settings layout.\n", stderr)
                exit(1)
            }
            view.cacheDisplay(in: view.bounds, to: image)
            do {
                guard let data = image.representation(using: .png, properties: [:]) else {
                    fputs("Could not encode Settings capture.\n", stderr)
                    exit(1)
                }
                let appearance = CommandLine.arguments.contains("--light") ? "light" : "dark"
                try data.write(to: URL(fileURLWithPath: "build/settings-\(appearance)-\(name).png"))
            } catch {
                fputs("Settings capture failed: \(error)\n", stderr)
                exit(1)
            }
        }

        private func finish() {
            do {
                precondition(fixture.controller.settings == fixture.initialSettings,
                    "Browsing Settings must not rewrite saved choices")
                let decoded = try JSONDecoder().decode(AppSettings.self,
                    from: JSONEncoder().encode(fixture.controller.settings))
                precondition(decoded == fixture.initialSettings)
                if !CommandLine.arguments.contains("--screenshots") {
                    precondition(!decoded.callStartRainbow)
                }
            } catch {
                fputs("Settings round-trip failed: \(error)\n", stderr)
                exit(1)
            }
            print("All four Settings tabs render at 760 x 1030 and preserve the fixture's saved settings.")
            window?.close()
            fixture.controller.shutdown()
            exit(0)
        }
    }
}
