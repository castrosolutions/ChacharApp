// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChacharApp",
    platforms: [
        .macOS(.v14) // target macOS 14+ (WhisperKit supports v13)
    ],
    products: [
        .library(name: "ChacharCore", targets: ["ChacharCore"]),
        .library(name: "ChacharCleanupMLX", targets: ["ChacharCleanupMLX"]),
        .executable(name: "chacharapp", targets: ["ChacharApp"]),
        .executable(name: "chacharapp-spike", targets: ["ChacharSpike"]),
        .executable(name: "chacharapp-bench", targets: ["ChacharBench"]),
    ],
    dependencies: [
        // WhisperKit (Argmax Open-Source SDK): on-device ASR engine (CoreML/ANE).
        // Pin to a real tag >= 1.0.0; the README's `from: "0.9.0"` is OBSOLETE.
        // .upToNextMinor => 1.0.x; NEVER .upToNextMajor. Package.resolved pins the commit.
        .package(
            url: "https://github.com/argmaxinc/WhisperKit.git",
            .upToNextMinor(from: "1.0.0")
        ),
        // MLX Swift examples (MLXLLM / MLXLMCommon): on-device LLM for Layer 2 cleanup.
        // Pin to 2.29.x; never upToNextMajor. Package.resolved pins the commit.
        .package(
            url: "https://github.com/ml-explore/mlx-swift-examples.git",
            .upToNextMinor(from: "2.29.1")
        ),
    ],
    targets: [
        .target(
            name: "ChacharCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        // Layer 2 cleanup, isolated so the heavy MLX dependency stays out of ChacharCore/tests.
        .target(
            name: "ChacharCleanupMLX",
            dependencies: [
                "ChacharCore",
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
            ]
        ),
        .executableTarget(name: "ChacharApp", dependencies: ["ChacharCore", "ChacharCleanupMLX"]),
        .executableTarget(name: "ChacharSpike", dependencies: ["ChacharCore"]),
        // Layer 2 cleanup benchmark — links MLX, so it must be built with xcodebuild (metallib).
        .executableTarget(name: "ChacharBench", dependencies: ["ChacharCore", "ChacharCleanupMLX"]),
        .testTarget(name: "ChacharCoreTests", dependencies: ["ChacharCore"]),
    ]
)
