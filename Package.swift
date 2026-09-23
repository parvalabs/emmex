// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mlex",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MlexCore", targets: ["MlexCore"]),
        .executable(name: "mlex", targets: ["mlex"]),
        .executable(name: "MlexApp", targets: ["MlexApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/anthropics/ClaudeForFoundationModels.git", from: "0.2.1"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
    ],
    targets: [
        .target(name: "MlexCore", dependencies: [
            .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "MCP", package: "swift-sdk"),
        ]),
        .executableTarget(name: "mlex", dependencies: [
            "MlexCore",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "MlexApp", dependencies: ["MlexCore"]),
        .executableTarget(name: "spike-transcript", dependencies: ["MlexCore"]),
        .executableTarget(name: "spike-claude", dependencies: [
            "MlexCore",
            .product(name: "ClaudeForFoundationModels", package: "ClaudeForFoundationModels"),
        ]),
        .executableTarget(name: "spike-mlx", dependencies: [
            "MlexCore",
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
    ]
)
