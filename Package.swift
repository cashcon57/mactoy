// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mactoy",
    platforms: [
        .macOS("26.0")
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
