// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "emmex",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "EmmexCore", targets: ["EmmexCore"]),
        .library(name: "EmmexServer", targets: ["EmmexServer"]),
        .executable(name: "emmex", targets: ["emmex"]),
        .executable(name: "EmmexApp", targets: ["EmmexApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels.git", from: "0.2.1"),
        .package(path: "Vendor/mlx-swift-lm"),   // upstream main @ ee673d6a plus our KV-cache reuse patch (see Vendor/mlx-swift-lm/EMMEX-PATCHES.md)
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/foundation-models-utilities", from: "1.0.0-beta1"),
    ],
    targets: [
        .target(name: "EmmexCore", dependencies: [
            .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "FoundationModelsUtilities", package: "foundation-models-utilities"),
        ]),
        .target(name: "EmmexServer", dependencies: ["EmmexCore"], resources: [.copy("Resources/web")]),
        .executableTarget(name: "emmex", dependencies: [
            "EmmexCore", "EmmexServer",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "EmmexApp", dependencies: ["EmmexCore", "EmmexServer"]),
        .testTarget(name: "EmmexCoreTests", dependencies: ["EmmexCore"]),
        .executableTarget(name: "spike-transcript", dependencies: ["EmmexCore"]),
        .executableTarget(name: "spike-claude", dependencies: [
            "EmmexCore",
            .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
        ]),
        .executableTarget(name: "spike-mlx", dependencies: [
            "EmmexCore",
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
    ]
)
