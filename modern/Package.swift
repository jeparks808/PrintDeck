// swift-tools-version: 6.0
// PrintDeck for current iPhones and iPads (iOS 17+), built on Linux with xtool (see README.md).
import PackageDescription

let package = Package(
    name: "PrintDeck",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool builds the app from the package's single library product.
        .library(name: "PrintDeck", targets: ["PrintDeck"]),
        // A command-line check of the printer code, for Linux and macOS.
        .executable(name: "pdcli", targets: ["pdcli"]),
    ],
    targets: [
        // Printer communication and models: no UI, builds and tests on Linux.
        .target(name: "PrintDeckCore"),
        // The SwiftUI app (iOS). Its files are wrapped in `#if canImport(SwiftUI)` so the package still builds on Linux.
        .target(name: "PrintDeck", dependencies: ["PrintDeckCore"]),
        .executableTarget(name: "pdcli", dependencies: ["PrintDeckCore"]),
        .testTarget(
            name: "PrintDeckCoreTests",
            dependencies: ["PrintDeckCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
