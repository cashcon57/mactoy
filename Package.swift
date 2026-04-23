// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mactoy",
    platforms: [
        // 13.5 floor, not 13.0. Pre-13.5 Ventura shipped multiple
        // SMAppService bugs (register() returning success while launchd
        // never loaded; BTM/launchd desync; "Operation not permitted"
        // on re-register loops). Fixes landed in 13.5 / 14.2.
        .macOS("13.5")
    ],
    products: [
        .library(name: "MactoyKit", targets: ["MactoyKit"]),
        .executable(name: "mactoyd", targets: ["mactoyd"]),
        .executable(name: "Mactoy", targets: ["Mactoy"])
    ],
    dependencies: [
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.6")
    ],
    targets: [
        .target(
            name: "MactoyKit",
            dependencies: [
                .product(name: "SWCompression", package: "SWCompression")
            ],
            path: "Sources/MactoyKit"
        ),
        .executableTarget(
            name: "mactoyd",
            dependencies: ["MactoyKit"],
            path: "Sources/mactoyd"
        ),
        .executableTarget(
            name: "Mactoy",
            dependencies: ["MactoyKit"],
            path: "Sources/Mactoy",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "MactoyKitTests",
            dependencies: ["MactoyKit"],
            path: "Tests/MactoyKitTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
