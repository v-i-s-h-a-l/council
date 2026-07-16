// swift-tools-version:6.3
import PackageDescription

let package = Package(
    name: "Council",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "CouncilCore", targets: ["CouncilCore"]),
        .library(name: "CouncilAgents", targets: ["CouncilAgents"]),
        .library(name: "CouncilInference", targets: ["CouncilInference"]),
        .library(name: "CouncilMemory", targets: ["CouncilMemory"]),
        .library(name: "CouncilUI", targets: ["CouncilUI"]),
        .executable(name: "council", targets: ["CouncilCLI"]),
    ],
    dependencies: [
        // Local fork of mlx-swift with #if os(macOS) guards on encuda's Process usage.
        // Upstream v0.31.5 fails to compile for iOS Simulator because encuda uses
        // Process (macOS/Linux only). See: council issue #16.
        .package(path: "/Users/vishalsingh/Documents/v-i-s-h-a-l/github/mlx-swift"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.9.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CouncilCore",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CouncilAgents",
            dependencies: [
                "CouncilCore",
                "CouncilMemory",
                "CouncilInference",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CouncilInference",
            dependencies: [
                "CouncilCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CouncilMemory",
            dependencies: [
                "CouncilCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CouncilUI",
            dependencies: [
                "CouncilCore",
                "CouncilAgents",
                "CouncilMemory",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "CouncilTestUtilities",
            dependencies: ["CouncilCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilCoreTests",
            dependencies: ["CouncilCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilAgentsTests",
            dependencies: ["CouncilAgents", "CouncilTestUtilities"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilInferenceTests",
            dependencies: ["CouncilInference", "CouncilTestUtilities"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilMemoryTests",
            dependencies: ["CouncilMemory", "CouncilTestUtilities"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilIntegrationTests",
            dependencies: [
                "CouncilCore",
                "CouncilAgents",
                "CouncilInference",
                "CouncilMemory",
                "CouncilTestUtilities",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilUITests",
            dependencies: [
                "CouncilUI",
                "CouncilCore",
                "CouncilAgents",
                "CouncilMemory",
                "CouncilTestUtilities",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "CouncilBenchmarks",
            dependencies: [
                "CouncilCore",
                "CouncilAgents",
                "CouncilInference",
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "CouncilCLI",
            dependencies: [
                "CouncilCore",
                "CouncilAgents",
                "CouncilInference",
                "CouncilMemory",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .testTarget(
            name: "CouncilCLITests",
            dependencies: [
                "CouncilCLI",
                "CouncilCore",
                "CouncilAgents",
                "CouncilMemory",
                "CouncilTestUtilities",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
