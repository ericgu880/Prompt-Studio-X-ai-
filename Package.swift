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
        .executable(name: "PromptStudioSmokeTests", targets: ["PromptStudioSmokeTests"])
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
            dependencies: ["PromptStudioCore"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "PromptStudioCLI",
            dependencies: ["PromptStudioCore"]
        ),
        .executableTarget(
            name: "PromptStudioSmokeTests",
            dependencies: ["PromptStudioCore"]
        ),
        .testTarget(
            name: "PromptStudioCoreTests",
            dependencies: ["PromptStudioCore"]
        )
    ]
)
