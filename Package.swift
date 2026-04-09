// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DodexaCode",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "DodexaCodeCore",
            targets: ["DodexaCodeCore"]
        ),
        .executable(
            name: "dodexacode",
            targets: ["dodexacode"]
        )
    ],
    targets: [
        .target(
            name: "DodexaCodeCore",
            path: "Sources/DodexaBashCore"
        ),
        .executableTarget(
            name: "dodexacode",
            dependencies: ["DodexaCodeCore"],
            path: "Sources/DodexaBash"
        ),
        .testTarget(
            name: "DodexaCodeCoreTests",
            dependencies: ["DodexaCodeCore"],
            path: "Tests/DodexaBashCoreTests"
        )
    ]
)
