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
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(controller)
        }
    }
}
