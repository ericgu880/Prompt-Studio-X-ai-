// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PromptStudio",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PromptStudio", targets: ["PromptStudio"]),
        .executable(name: "promptstudioctl", targets: ["PromptStudioCLI"]),
        .executable(name: "PromptStudioMCP", targets: ["PromptStudioMCP"]),
        .executable(name: "PromptStudioCoreUnitTests", targets: ["PromptStudioCoreUnitTests"]),
        .executable(name: "PromptStudioSmokeTests", targets: ["PromptStudioSmokeTests"]),
        .executable(name: "PromptStudioCaptureHost", targets: ["PromptStudioCaptureHost"]),
        .executable(name: "PromptStudioLibraryQueryBenchmark", targets: ["PromptStudioLibraryQueryBenchmark"]),
        .executable(name: "PromptStudioTagRelationBenchmark", targets: ["PromptStudioTagRelationBenchmark"]),
        .executable(name: "PromptStudioLibraryDetailBenchmark", targets: ["PromptStudioLibraryDetailBenchmark"]),
        .executable(name: "PromptStudioPhase2A4Benchmark", targets: ["PromptStudioPhase2A4Benchmark"])
    ],
    dependencies: [
        .package(url: "https://github.com/airbnb/lottie-spm.git", from: "4.6.0")
    ],
    targets: [
        .target(
            name: "PromptStudioCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "PromptStudio",
            dependencies: [
                "PromptStudioCore",
                .product(name: "Lottie", package: "lottie-spm")
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "PromptStudioCLI",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioMCP",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioCoreUnitTests",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioSmokeTests",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioCaptureHost",
            path: "Sources/PromptStudioCaptureHost"
        ),
        .executableTarget(
            name: "PromptStudioLibraryQueryBenchmark",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioTagRelationBenchmark",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioLibraryDetailBenchmark",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioPhase2A4Benchmark",
            dependencies: ["PromptStudioCore"]
        ),
        .testTarget(
            name: "PromptStudioCoreTests",
            dependencies: ["PromptStudioCore"]
        ),
        .testTarget(
            name: "PromptStudioCaptureHostTests",
            dependencies: ["PromptStudioCaptureHost"]
        )
    ]
)
