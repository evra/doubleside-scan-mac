// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DuplexScan",
    platforms: [.macOS(.v15)],
    targets: [
        // libscanline (github.com/klep/scanline, git submodule in Vendor/scanline), exposed via symlinks.
        .target(
            name: "ScanlineConfiguration",
            path: "Sources/ScanlineConfiguration",
            publicHeadersPath: "include"
        ),
        .target(
            name: "LibScanline",
            dependencies: ["ScanlineConfiguration"],
            path: "Sources/LibScanline"
        ),
        .executableTarget(
            name: "DuplexScan",
            dependencies: ["LibScanline"],
            path: "Sources/DuplexScan"
        ),
        .testTarget(
            name: "DuplexScanTests",
            dependencies: ["DuplexScan"],
            path: "Tests/DuplexScanTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
