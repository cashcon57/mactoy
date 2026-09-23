// swift-tools-version: 6.0
import PackageDescription

// Standalone harness — not part of the main package graph. See README.md.
let package = Package(
    name: "e2e",
    platforms: [.macOS("13.5")],
    dependencies: [.package(name: "Mactoy", path: "../..")],
    targets: [.executableTarget(name: "e2e", dependencies: [.product(name: "MactoyKit", package: "Mactoy")])]
)
