import AppKit

protocol FirmwareTerminationState: AnyObject {
    var busy: Bool { get }
    var protectedOperation: Bool { get }
    var showingProgress: Bool { get set }
    func cancel()
}

final class FirmwareApplicationDelegate: NSObject, NSApplicationDelegate {
    static weak var manager: FirmwareTerminationState?
    private var waitingToQuit = false
    var blockedQuitNotification: (() -> Void)?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let manager = Self.manager, manager.busy else { return .terminateNow }
        if manager.protectedOperation {
            manager.showingProgress = true
            if let blockedQuitNotification {
                blockedQuitNotification()
                return .terminateCancel
            }
            let alert = NSAlert()
            alert.messageText = "Firmware operation in progress"
            alert.informativeText = "Keep the app open and the board connected until writing and verification finish. Quitting is temporarily disabled."
            alert.addButton(withTitle: "Keep App Open")
            alert.runModal()
            return .terminateCancel
        }
        manager.cancel()
        if !waitingToQuit {
            waitingToQuit = true
            waitForSafeQuit(sender)
        }
        return .terminateLater
    }

    private func waitForSafeQuit(_ app: NSApplication) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            if Self.manager?.busy != true {
                self.waitingToQuit = false
                app.reply(toApplicationShouldTerminate: true)
            } else {
                self.waitForSafeQuit(app)
            }
        }
    }
}
