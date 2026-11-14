import SwiftUI

struct HexColorEntry {
    var text: String
    private(set) var error: String?

    init(color: RGB) { text = color.hex }

    mutating func apply(to color: inout RGB) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let parsed = RGB(string: digits) else {
            error = "Enter six hex digits, such as #FF8000."
            return false
        }
        color = parsed
        text = parsed.hex
        error = nil
        return true
    }
}

private final class ColorPickerState: ObservableObject {
    @Published var choosing = false
    @Published var entry: HexColorEntry

    init(color: RGB = .off) { entry = HexColorEntry(color: color) }
}

struct ColorSwatchPicker: View {
    @Binding var selection: RGB
    var label = "Color"
    @StateObject private var ui = ColorPickerState()

    var body: some View {
        Button { ui.choosing = true } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(selection.color)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25)))
                    .frame(width: 14, height: 14)
                Text(selection.isOff ? "Off" : selection.hex)
                    .font(.caption.monospaced())
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .accessibilityLabel("\(label): \(selection.isOff ? "Off" : selection.hex). Choose color")
        .popover(isPresented: $ui.choosing) {
            ColorSwatchChooser(selection: $selection) { ui.choosing = false }
        }
    }
}

struct ColorSwatchChooser: View {
    @Binding var selection: RGB
    let dismiss: () -> Void
    @StateObject private var ui: ColorPickerState

    private static let swatches: [(String, RGB)] = [
        ("White", RGB(r: 255, g: 255, b: 255)), ("Silver", RGB(r: 192, g: 192, b: 192)),
        ("Gray", RGB(r: 128, g: 128, b: 128)), ("Off", .off),
        ("Red", .red), ("Orange", RGB(r: 255, g: 128, b: 0)),
        ("Amber", RGB(r: 255, g: 191, b: 0)), ("Yellow", RGB(r: 255, g: 255, b: 0)),
        ("Lime", RGB(r: 128, g: 255, b: 0)), ("Green", .green),
        ("Teal", RGB(r: 0, g: 128, b: 128)), ("Cyan", RGB(r: 0, g: 255, b: 255)),
        ("Blue", .blue), ("Indigo", RGB(r: 75, g: 0, b: 130)),
        ("Purple", RGB(r: 128, g: 0, b: 255)), ("Pink", RGB(r: 255, g: 64, b: 128)),
    ]

    init(selection: Binding<RGB>, dismiss: @escaping () -> Void) {
        _selection = selection
        self.dismiss = dismiss
        _ui = StateObject(wrappedValue: ColorPickerState(color: selection.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a color").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 4), spacing: 8) {
                ForEach(Self.swatches.indices, id: \.self) { index in
                    let (name, color) = Self.swatches[index]
                    Button {
                        selection = color
                        dismiss()
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 5)
                                .fill(color.color)
                                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.25)))
                                .frame(height: 32)
                            Text(name).font(.caption)
                        }
                        .padding(5)
                        .background(selection == color ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(selection == color ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(name == "Off" ? "Black turns this light off" : "\(name) \(color.hex)")
                    .accessibilityLabel("\(name), \(color.hex)")
                    .accessibilityAddTraits(selection == color ? .isSelected : [])
                }
            }
            Divider()
            Text("Custom hex color").font(.subheadline)
            HStack {
                TextField("#RRGGBB", text: $ui.entry.text)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Custom hex color")
                    .onSubmit(apply)
                Button("Apply", action: apply)
            }
            if let error = ui.entry.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 328)
        .background(.background)
    }

    private func apply() {
        if ui.entry.apply(to: &selection) { dismiss() }
    }
}
