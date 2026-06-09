// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VibeShare",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VibeShare", targets: ["VibeShare"])
    ],
    targets: [
        .executableTarget(
            name: "VibeShare",
            path: "Sources",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
