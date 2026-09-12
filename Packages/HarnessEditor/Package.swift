// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessEditor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HarnessEditor", targets: ["HarnessEditor"]),
    ],
    dependencies: [
        .package(path: "../HarnessCore"),
    ],
    targets: [
        .target(
            name: "HarnessEditor",
            dependencies: ["HarnessCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HarnessEditorTests",
            dependencies: ["HarnessEditor"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
