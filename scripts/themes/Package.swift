// swift-tools-version: 6.0
import PackageDescription

// Standalone maintainer tool, like scripts/e2e. See CONTRIBUTING.md → Adding a boot theme.
let package = Package(
    name: "mactoy-themes",
    platforms: [.macOS("13.5")],
    dependencies: [.package(name: "Mactoy", path: "../..")],
    targets: [.executableTarget(name: "mactoy-themes", dependencies: [.product(name: "MactoyKit", package: "Mactoy")])]
)
