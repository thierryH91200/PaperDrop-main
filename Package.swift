// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperDrop",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ScanKit", path: "Sources/ScanKit"),
        .executableTarget(
            name: "PaperDrop", dependencies: ["ScanKit"],
            path: "Sources/PaperDrop"
        ),
        .executableTarget(
            name: "scantool", dependencies: ["ScanKit"],
            path: "Sources/scantool"
        ),
        .testTarget(
            name: "ScanKitTests", dependencies: ["ScanKit"],
            path: "Tests/ScanKitTests"
        ),
    ]
)
