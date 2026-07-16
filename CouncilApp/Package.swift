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
        .package(path: "/Users/vishalsingh/Documents/v-i-s-h-a-l/github/GRDB.swift-sqlcipher"),
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
                .product(name: "GRDB", package: "GRDB.swift-sqlcipher"),
            ],
            path: "Sources/CouncilApp",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
