// swift-tools-version: 6.0
import PackageDescription

// SwiftTerm is added in M4. Note: SwiftTerm ≥ 1.18 compiles Metal shaders and therefore
// needs the Xcode Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`).
let package = Package(
    name: "HarnessTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HarnessTerminal", targets: ["HarnessTerminal"]),
    ],
    dependencies: [
        .package(path: "../HarnessCore"),
    ],
    targets: [
        .target(
            name: "HarnessTerminal",
            dependencies: ["HarnessCore"],
            swiftSettings: [.enableUpcomingFeature("ExistentialAny")]
        ),
        .testTarget(
            name: "HarnessTerminalTests",
            dependencies: ["HarnessTerminal"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
