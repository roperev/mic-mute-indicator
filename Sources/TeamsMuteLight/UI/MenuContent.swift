import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var c: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Text(c.statusHeadline)

        if let problem = c.problem {
            Button("⚠︎ \(problem.message)…") {
                if problem == .needsAccessibility { c.requestAccessibility() } else { showSettings() }
            }
        }

        if c.api.status == .connected && c.api.canPair {
            Button("Pair with Teams…") { c.teamsAPI.pair() }
        }

        Divider()

        Toggle("Pause Lights", isOn: $c.paused)

        Menu("Test Lights") {
            ForEach([MicState.unmuted, .muted, .notInMeeting]) { s in
                Button(s.label) { c.preview(s) }
            }
            Divider()
            Button("Rainbow Sweep") { c.testRainbow() }
        }

        if c.api.status == .paired && c.api.canToggleMute {
            Button("Toggle Teams Mute") { c.teamsAPI.toggleMute() }
        }

        Divider()

        Button("Settings…") { showSettings() }
            .keyboardShortcut(",")

        Button("Quit Teams Mute Light") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
        .disabled(c.firmware.protectedOperation)
    }

    private func showSettings() {
        NSApp.activate()
        openSettings()
    }
}
