// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentRemote",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgentRemote",
            path: "Sources/AgentRemote",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
            ]
        )
    ]
)
