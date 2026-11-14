import SwiftUI
import UniformTypeIdentifiers

private final class FirmwarePresentation: ObservableObject {
    enum NextAction { case install, confirmWithoutBackup }
    @Published var installing = false
    @Published var inspectConfirmation = false
    @Published var restoreConfirmation = false
    @Published var eraseConfirmation = false
    @Published var importConfirmation = false
    @Published var backup = true
    @Published var useMatrix = true
    @Published var confirmedBoard = false
    @Published var factoryBackup = false
    var confirmationMAC = ""
    var nextAction: NextAction?
    var importURL: URL?
}

struct FirmwareManagementView: View {
    @ObservedObject var manager: FirmwareManager
    @StateObject private var ui = FirmwarePresentation()

    private var color: Color {
        switch manager.selectedState.appearance {
        case .neutral: return .secondary
        case .ready: return .green
        case .information: return .blue
        case .warning: return .orange
        }
    }

    private var symbol: String {
        switch manager.selectedState.appearance {
        case .neutral: return "cable.connector"
        case .ready: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        Section("Matrix firmware") {
            if manager.devices.isEmpty && !manager.busy {
                Label("Connect a Waveshare ESP32-S3-Matrix with a USB data cable.", systemImage: "cable.connector")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Device", selection: $manager.selectedPath) {
                    ForEach(manager.devices) { device in
                        Text(device.displayName).tag(device.path)
                    }
                    if !manager.devices.contains(where: { $0.path == manager.selectedPath }) {
                        Text("Device reconnecting…").tag(manager.selectedPath)
                    }
                }
                .disabled(manager.busy)
                Label(manager.selectedState.message, systemImage: symbol)
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                if let mac = manager.selectedState.mac {
                    LabeledContent("Recorded chip identity", value: mac)
                        .textSelection(.enabled)
                        .help("Recorded from inspection or a matching retained backup. The actual chip identity is checked again before every write.")
                }
                LabeledContent("Bundled MicMatrix build", value: manager.bundledBuild)
                HStack {
                    Button("Inspect firmware…") { ui.inspectConfirmation = true }
                        .help("Reset into the bootloader to verify the ESP32-S3 chip, MAC, flash size and firmware fingerprint. Does not write flash.")
                    Button("Install MicMatrix…") {
                        ui.backup = true
                        ui.useMatrix = true
                        ui.confirmedBoard = false
                        ui.nextAction = nil
                        ui.confirmationMAC = manager.selectedState.mac ?? ""
                        ui.installing = true
                    }
                    .disabled(manager.selectedState.mac == nil)
                    Spacer()
                    Button("Refresh") { manager.checkConnection() }
                }
                .disabled(manager.busy)
                if let (backup, _) = manager.original {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Original firmware backup").font(.subheadline.bold())
                        Text(backup.firmware).foregroundStyle(.secondary)
                        Text(backup.imagePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Label("Checksum verified", systemImage: "checkmark.shield")
                                .foregroundStyle(.green).font(.caption)
                            Spacer()
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup.imagePath)])
                            }
                            Button("Flash back to original firmware…") {
                                ui.confirmationMAC = manager.selectedState.mac ?? ""
                                ui.restoreConfirmation = true
                            }
                                .disabled(manager.busy)
                                .help("Overwrite this board's firmware with its registered original backup")
                        }
                    }
                } else {
                    Text("No verified original backup is registered for this board. Installation backs it up by default. Flashing back is unavailable without an original backup.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Choose an existing backup file…", action: chooseBackup)
                    .disabled(manager.busy || manager.selectedState.mac == nil)
                    .help("Register a backup file from this exact board. This does not flash or change the board.")
                Text(manager.original == nil
                    ? "Set a file from this board as its original backup. Choosing a file does not flash the board."
                    : "Add a backup file from this board. Your registered original stays unchanged; choosing a file does not flash the board.")
                    .font(.caption).foregroundStyle(.secondary)
                if manager.busy {
                    Button("Show firmware progress") { manager.showingProgress = true }
                }
            }
            if let error = manager.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).font(.callout)
                    .textSelection(.enabled)
            }
            if let recovery = manager.recoveryMessage {
                Text(recovery).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
        .sheet(isPresented: $ui.installing, onDismiss: completeInstallConfirmation) { installSheet }
        .sheet(isPresented: $manager.showingProgress) { progressSheet }
        .alert("Inspect this device?", isPresented: $ui.inspectConfirmation) {
            Button("Inspect") { manager.inspect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The selected device will reset into its download bootloader. This reads its identity and firmware fingerprint without changing flash. Only use this with your Waveshare ESP32-S3-Matrix. If needed, hold BOOT, press and release RESET, then release BOOT.")
        }
        .alert("Erase WITHOUT a backup?", isPresented: $ui.eraseConfirmation) {
            Button("Erase and install without backup", role: .destructive) {
                manager.install(backup: false, skipConfirmed: true, use: ui.useMatrix,
                    confirmedMAC: ui.confirmationMAC)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All existing contents of \(manager.selectedState.mac ?? "this board") will be destroyed. If no original backup already exists, you cannot restore its original firmware with this app. Keep the board connected. This choice applies only to this installation.")
        }
        .alert("Flash back to original firmware?", isPresented: $ui.restoreConfirmation) {
            Button("Flash original firmware", role: .destructive) {
                manager.restore(confirmedMAC: ui.confirmationMAC)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This overwrites all flash on \(manager.selectedState.mac ?? "this board") with its verified original backup and disables this board's matrix output. The app and other lights keep running. Backup: \(manager.original?.0.imagePath ?? "unavailable"). Do not unplug the board.")
        }
        .alert("Register this backup file?", isPresented: $ui.importConfirmation) {
            Button(manager.original == nil ? "Set as original backup" : "Add backup file") {
                if let url = ui.importURL {
                    manager.importOriginal(url, factory: ui.factoryBackup, confirmedMAC: ui.confirmationMAC)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Confirm that \(ui.importURL?.lastPathComponent ?? "this image") is a complete backup from this exact board (\(manager.selectedState.mac ?? "unknown")). This registers the file only; it does not flash or change the board. File checks cannot prove which board created it. If no original is registered, this becomes the original backup. Otherwise it is added separately without replacing the original.")
        }
    }

    private var installSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Install MicMatrix").font(.title2.bold())
            Text("Replace all firmware and saved data on this board with bundled MicMatrix.")
            Text(manager.selectedState.mac ?? "Inspect this device first.")
                .font(.body.monospaced()).textSelection(.enabled)
            Toggle("I confirm this is a Waveshare ESP32-S3-Matrix (4 MiB)", isOn: $ui.confirmedBoard)
            Text("Espressif USB IDs identify the chip family, not the board model. Do not install on another ESP32 board.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Back up current firmware (recommended)", isOn: $ui.backup)
            Text("A complete verified backup is saved before erasing. Your first original is preserved; later backups are separate snapshots.")
                .font(.caption).foregroundStyle(.secondary)
            Text(FirmwareBackupStore.root.path).font(.caption.monospaced()).textSelection(.enabled)
            Toggle("Use this matrix for status lights after installation", isOn: $ui.useMatrix)
            Text("Keep the app open and USB connected through verification. Normal Quit and cancellation are blocked during flashing. Force Quit, power loss and unplugging cannot be prevented.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) {
                    ui.nextAction = nil
                    ui.installing = false
                }
                Spacer()
                Button(ui.backup ? "Back up and install" : "Continue without backup…") {
                    ui.nextAction = ui.backup ? .install : .confirmWithoutBackup
                    ui.installing = false
                }
                .disabled(!ui.confirmedBoard || manager.selectedState.mac == nil)
            }
        }
        .padding(24).frame(width: 520)
    }

    private var progressSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(manager.busy ? "Matrix firmware operation" : "Firmware result").font(.title2.bold())
            Text(manager.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if manager.busy {
                if let progress = manager.progress { ProgressView(value: progress) }
                else { ProgressView() }
            }
            if manager.protectedOperation {
                Label("Do not unplug. Quit, relaunch and cancellation are disabled until verification finishes.",
                    systemImage: "lock.shield")
                    .foregroundStyle(.orange)
            }
            Text("If connection fails, hold BOOT, press and release RESET, then release BOOT. Retry with the same board. Backups are retained even if the operation fails.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                if manager.busy {
                    Button("Cancel before erasure") { manager.cancel() }
                        .disabled(manager.protectedOperation)
                } else {
                    Button("Done") { manager.showingProgress = false }
                }
            }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(manager.busy)
    }

    private func chooseBackup() {
        ui.confirmationMAC = manager.selectedState.mac ?? ""
        let panel = NSOpenPanel()
        panel.title = "Choose this board's complete original flash backup"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url {
                ui.importURL = url
                ui.factoryBackup = false
                ui.importConfirmation = true
            }

        }
    }

    private func completeInstallConfirmation() {
        let next = ui.nextAction
        ui.nextAction = nil
        switch next {
        case .install:
            manager.install(backup: true, skipConfirmed: false, use: ui.useMatrix,
                confirmedMAC: ui.confirmationMAC)
        case .confirmWithoutBackup:
            ui.eraseConfirmation = true
        case nil:
            break
        }
    }
}
