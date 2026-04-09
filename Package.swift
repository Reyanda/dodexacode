// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DodexaBash",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DodexaBashCore",
            targets: ["DodexaBashCore"]
        ),
        .executable(
            name: "dodexabash",
            targets: ["DodexaBash"]
        )
    ],
    targets: [
        .target(
            name: "DodexaBashCore"
        ),
        .executableTarget(
            name: "DodexaBash",
            dependencies: ["DodexaBashCore"]
        ),
        .testTarget(
            name: "DodexaBashCoreTests",
            dependencies: ["DodexaBashCore"]
        )
    ]
)
