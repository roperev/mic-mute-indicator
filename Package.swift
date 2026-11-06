// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TeamsMuteLight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "TeamsMuteLight",
            path: "Sources/TeamsMuteLight",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
