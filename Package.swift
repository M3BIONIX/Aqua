// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aqua",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aqua", targets: ["Aqua"]),
        .executable(name: "aqua-cli", targets: ["aqua-cli"]),
    ],
    targets: [
        .target(
            name: "AquaCore",
            resources: [.copy("Resources/recipes.json")]
        ),
        .executableTarget(
            name: "Aqua",
            dependencies: ["AquaCore"],
            resources: [.copy("Resources/Fonts")]
        ),
        .executableTarget(
            name: "aqua-cli",
            dependencies: ["AquaCore"]
        ),
        .testTarget(
            name: "AquaCoreTests",
            dependencies: ["AquaCore"]
        ),
    ]
)
