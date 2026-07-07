// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "CouncilApp",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(path: "../Council"),
    ],
    targets: [
        .executableTarget(
            name: "CouncilApp",
            dependencies: [
                .product(name: "CouncilUI", package: "Council"),
                .product(name: "CouncilCore", package: "Council"),
                .product(name: "CouncilAgents", package: "Council"),
                .product(name: "CouncilMemory", package: "Council"),
                .product(name: "CouncilInference", package: "Council"),
            ],
            path: "Sources/CouncilApp",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
