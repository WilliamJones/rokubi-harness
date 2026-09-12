// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
    ],
    targets: [
        .target(
            name: "HarnessCore",
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HarnessCoreTests",
            dependencies: ["HarnessCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
