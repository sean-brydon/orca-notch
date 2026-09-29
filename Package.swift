// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrcaNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OrcaNotch",
            path: "Sources/OrcaNotch"
        ),
    ]
)
