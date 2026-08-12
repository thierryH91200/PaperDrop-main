// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperDrop",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ScanKit", path: "Sources/ScanKit"),
        .executableTarget(
            name: "PaperDrop", dependencies: ["ScanKit"],
            path: "Sources/PaperDrop",
            // The String Catalog is compiled by the Xcode project (the real
            // build); this secondary SwiftPM build only checks compilation.
            exclude: ["Localizable.xcstrings"]
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
