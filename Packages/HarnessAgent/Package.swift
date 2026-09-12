// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessAgent",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HarnessAgent", targets: ["HarnessAgent"]),
    ],
    dependencies: [
        .package(path: "../HarnessCore"),
    ],
    targets: [
        .target(
            name: "HarnessAgent",
            dependencies: ["HarnessCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HarnessAgentTests",
            dependencies: ["HarnessAgent"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
