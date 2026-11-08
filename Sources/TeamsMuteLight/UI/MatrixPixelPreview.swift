import SwiftUI

struct MatrixPixelPreview: View {
    let pixels: [RGB]
    var scale: CGFloat = 1

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(10 * scale), spacing: 3 * scale), count: 8), spacing: 3 * scale) {
            ForEach(pixels.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2 * scale)
                    .fill(pixels[index].isOff ? Color.white.opacity(0.12) : pixels[index].color)
                    .frame(width: 10 * scale, height: 10 * scale)
            }
        }
        .padding(10 * scale)
        .background(Color(red: 0.035, green: 0.055, blue: 0.065), in: RoundedRectangle(cornerRadius: 8 * scale))
        .fixedSize()
        .accessibilityLabel("8 by 8 LED artwork preview; simulated colors, not physical brightness")
    }
}
