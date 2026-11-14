import SwiftUI

struct MatrixStatusEditor: View {
    @Binding var config: MatrixConfig
    let preview: (MicState) -> Void
    private let states: [MicState] = [.unmuted, .muted, .notInMeeting]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(states) { state in
                MatrixStatusCard(state: state, icon: $config.icons[state],
                    color: $config.light.colors[state], style: $config.colorStyles[state],
                    brightness: $config.brightnessLevels[state]) {
                    preview(state)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }
}

private final class MatrixCardState: ObservableObject {
    @Published var choosingIcon = false
    var previousColor = RGB.green
}

private struct MatrixStatusCard: View {
    let state: MicState
    @Binding var icon: MatrixIcon
    @Binding var color: RGB
    @Binding var style: MatrixColorStyle
    @Binding var brightness: Double
    let preview: () -> Void
    @StateObject private var ui = MatrixCardState()

    private var enabled: Binding<Bool> {
        Binding(get: { !color.isOff }, set: { show in
            if show { color = ui.previousColor }
            else { ui.previousColor = color; color = .off }
        })
    }

    private var title: String {
        switch state {
        case .unmuted: return "Live"
        case .muted: return "Muted"
        case .notInMeeting: return "Not in meeting"
        case .unknown: return "Unavailable"
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.subheadline.bold())
                .lineLimit(1)
                .padding(.horizontal, 35)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Button("Test", action: preview)
                        .controlSize(.small)
                        .help("Preview \(title) on all enabled lights for three seconds")
                        .accessibilityLabel("Test \(title) lights")
                }
            Button { ui.choosingIcon = true } label: {
                VStack(spacing: 5) {
                    MatrixIconPreview(icon: icon, color: color, style: style)
                    Text(icon == .orientation ? "Up arrow" : icon.label)
                        .font(.caption).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title) icon: \(icon.label). Choose icon")
            .popover(isPresented: $ui.choosingIcon) {
                MatrixIconChooser(selection: $icon) { ui.choosingIcon = false }
            }
            Toggle("Enabled", isOn: enabled)
                .toggleStyle(.switch).controlSize(.small)
                .accessibilityLabel("\(title) enabled")
            VStack(spacing: 8) {
                Picker("Color mode", selection: $style) {
                    ForEach(MatrixColorStyle.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .accessibilityLabel("\(title) color mode")
                .disabled(color.isOff)
                HStack {
                    if style != .artwork {
                        ColorSwatchPicker(selection: $color, label: "\(title) color")
                            .controlSize(.small)
                            .disabled(color.isOff)
                    }
                }
                .frame(height: 24)
            }
            HStack(spacing: 6) {
                Slider(value: $brightness, in: 0...1)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel("\(title) brightness, percent of master")
                    .help("State brightness")
                Text("\(Int((brightness * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .onAppear { if !color.isOff { ui.previousColor = color } }
        .onChange(of: color) { _, value in
            if !value.isOff { ui.previousColor = value }
        }
    }
}

private struct MatrixIconChooser: View {
    @Binding var selection: MatrixIcon
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an 8x8 icon").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 8), count: 4), spacing: 8) {
                ForEach(MatrixIcon.allCases) { icon in
                    Button {
                        selection = icon
                        dismiss()
                    } label: {
                        VStack(spacing: 5) {
                            MatrixIconPreview(icon: icon, scale: 0.5)
                            Text(icon == .orientation ? "Up arrow" : icon.label)
                                .font(.caption).lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(height: 28)
                        }
                        .padding(4)
                        .background(selection == icon ? Color.accentColor.opacity(0.18) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == icon ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(icon.label)
                    .accessibilityAddTraits(selection == icon ? .isSelected : [])
                }
            }
        }
        .padding(16)
    }
}

private struct MatrixIconPreview: View {
    let icon: MatrixIcon
    var color: RGB = .green
    var style: MatrixColorStyle = .artwork
    var scale = 1.0

    private var previewColor: RGB { MatrixColorCalibration.previewColor(color, style: style) }

    var body: some View {
        if icon.isAnimated {
            TimelineView(.animation(minimumInterval: 0.125)) { context in
                MatrixPixelPreview(pixels: MatrixFrame(color: previewColor, brightness: 0.02,
                    rotation: 0, icon: icon, style: style,
                    animationTime: context.date.timeIntervalSinceReferenceDate).pixels, scale: scale)
            }
        } else {
            MatrixPixelPreview(pixels: MatrixFrame(color: previewColor, brightness: 0.02,
                rotation: 0, icon: icon, style: style).pixels, scale: scale)
        }
    }
}
