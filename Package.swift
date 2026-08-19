// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackpadTyping",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "MTBridge"),
        .executableTarget(
            name: "TrackpadTyping",
            dependencies: ["MTBridge"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]
        ),
    ]
)
