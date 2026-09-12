// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessUI",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HarnessUI", targets: ["HarnessUI"]),
    ],
    dependencies: [
        .package(path: "../HarnessCore"),
        .package(path: "../HarnessAgent"),
        .package(path: "../HarnessEditor"),
        .package(path: "../HarnessTerminal"),
    ],
    targets: [
        .target(
            name: "HarnessUI",
            dependencies: ["HarnessCore", "HarnessAgent", "HarnessEditor", "HarnessTerminal"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HarnessUITests",
            dependencies: ["HarnessUI"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
