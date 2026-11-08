import Foundation

@main
enum MatrixGallery {
    static func main() throws {
        let animated = CommandLine.arguments.contains("--animated")
        let icons = MatrixIcon.allCases.filter { $0 != .off }
        let variants: [(String, Bool, RGB)] = [
            ("Full-color artwork", true, .green),
            ("Single-color red", false, .red),
            ("Single-color cyan", false, RGB(r: 0, g: 210, b: 255)),
        ]
        let width = 1024
        let height = 145 + ((icons.count + 3) / 4) * 340
        var svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)" role="img" aria-labelledby="title desc">
        <title id="title">MicMatrix full-color 8x8 LED gallery</title>
        <desc id="desc">Exact pixel artwork and two single-color variants on simulated dark circuit boards. LED glow is illustrative, not a brightness or thermal measurement.</desc>
        <defs>
          <filter id="glow" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="4"/></filter>
          <linearGradient id="board" x2="1" y2="1"><stop stop-color="#10272a"/><stop offset="1" stop-color="#091015"/></linearGradient>
        </defs>
        <rect width="100%" height="100%" fill="#080c12"/>
        <g fill="#e5edf5" font-family="system-ui, sans-serif">
        <text x="32" y="40" font-size="25" font-weight="700">MicMatrix / 8x8 pixel gallery</text>
        <text x="32" y="67" font-size="13" fill="#93a9bb">Shared device artwork. New-install master 9%; maximum 10%. Preview glow is illustrative.</text>
        """
        svg += "<text x=\"32\" y=\"94\" font-size=\"13\" fill=\"#93a9bb\">Large boards: full color. Small boards beneath: red / cyan single-color alternatives.</text>"
        for (row, icon) in icons.enumerated() {
            let top = 145 + (row / 4) * 340
            let baseLeft = 32 + (row % 4) * 248
            let label = icon == .orientation ? "Orientation test"
                : icon == .afk ? "AFK (A / F / K)" : icon == .shrug ? "Shrug (scrolls left)" : icon.label
            svg += "<text x=\"\(baseLeft)\" y=\"\(top - 15)\" font-size=\"15\">\(label)</text>"
            svg += "<text x=\"\(baseLeft)\" y=\"\(top + 307)\" font-size=\"11\" fill=\"#93a9bb\">Red / cyan alternatives</text>"
            for (column, variant) in variants.enumerated() {
                let left = baseLeft + (column == 2 ? 96 : 0)
                let boardTop = top + (column > 0 ? 198 : 0)
                let scale = column == 0 ? "1" : "0.5"
                let frame = MatrixFrame(color: variant.2, brightness: MatrixFrame.defaultLevel,
                                        rotation: 0, icon: icon, fullColor: variant.1)
                let animateIcon = animated && icon.isAnimated
                let count = !animateIcon ? 1 : icon == .afk ? 3 : MatrixIconAnimation.shrugWidth + 8
                let interval = icon == .afk ? MatrixIconAnimation.letterDuration : 0.125
                let frames = (0..<count).map { step in
                    MatrixFrame(color: variant.2, brightness: MatrixFrame.defaultLevel,
                        rotation: 0, icon: icon, fullColor: variant.1,
                        animationTime: animateIcon ? Double(step) * interval : nil).pixels
                }
                precondition(frame.pixels.count == 64)
                svg += """
                <g transform="translate(\(left),\(boardTop)) scale(\(scale))">
                <rect width="176" height="184" rx="14" fill="url(#board)" stroke="#365052"/>
                <path d="M8 35H168 M8 150H168 M22 12V170 M154 12V170" stroke="#2a4442" opacity=".45" fill="none"/>
                <rect x="68" y="0" width="40" height="10" rx="3" fill="#9da6ae"/><rect x="74" y="2" width="28" height="5" rx="2" fill="#242a32"/>
                """
                for index in 0..<64 {
                    let x = 15 + (index % 8) * 19
                    let y = 20 + (index / 8) * 19
                    let color = frames[0][index]
                    svg += "<rect x=\"\(x)\" y=\"\(y)\" width=\"13\" height=\"13\" rx=\"3\" fill=\"#b3bdba\" opacity=\".16\" stroke=\"#dbe5df\" stroke-opacity=\".1\"/>"
                    if frames.contains(where: { !$0[index].isOff }) {
                        let duration = Double(count) * interval
                        let fills = frames.map { $0[index].hex }.joined(separator: ";")
                        let opacity = frames.map { $0[index].isOff ? "0" : "1" }.joined(separator: ";")
                        let fillAnimation = animateIcon
                            ? "<animate attributeName=\"fill\" values=\"\(fills)\" dur=\"\(duration)s\" calcMode=\"discrete\" repeatCount=\"indefinite\"/>" : ""
                        svg += "<g opacity=\"\(color.isOff ? 0 : 1)\">"
                        if animateIcon {
                            svg += "<animate attributeName=\"opacity\" values=\"\(opacity)\" dur=\"\(duration)s\" calcMode=\"discrete\" repeatCount=\"indefinite\"/>"
                        }
                        svg += "<rect x=\"\(x - 1)\" y=\"\(y - 1)\" width=\"15\" height=\"15\" rx=\"4\" fill=\"\(color.hex)\" opacity=\".8\" filter=\"url(#glow)\">\(fillAnimation)</rect>"
                        svg += "<rect x=\"\(x + 1)\" y=\"\(y + 1)\" width=\"11\" height=\"11\" rx=\"3\" fill=\"\(color.hex)\">\(fillAnimation)</rect><rect x=\"\(x + 4)\" y=\"\(y + 3)\" width=\"4\" height=\"3\" rx=\"1\" fill=\"white\" opacity=\".28\"/></g>"
                    }
                }
                svg += "</g>"
            }
        }
        svg += "</g></svg>\n"
        let path = CommandLine.arguments.dropFirst().first { $0 != "--animated" }
            ?? "Resources/matrix-gallery.svg"
        try svg.write(toFile: path, atomically: true, encoding: .utf8)
        print("Generated \(icons.count * variants.count) exact 8x8 previews: \(path)")
    }
}
