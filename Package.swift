// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Beacon",
            path: "Sources/Beacon"
        )
    ]
)
