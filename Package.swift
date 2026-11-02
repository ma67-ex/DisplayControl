// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DisplayControl",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DisplayControlCore", targets: ["DisplayControlCore"]),
        .executable(name: "DisplayControlApp", targets: ["DisplayControlApp"]),
        .executable(name: "displaycontrol", targets: ["displaycontrol"]),
    ],
    targets: [
        .target(
            name: "DisplayControlCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(name: "DisplayControlApp", dependencies: ["DisplayControlCore"]),
        .executableTarget(name: "displaycontrol", dependencies: ["DisplayControlCore"]),
        .testTarget(name: "DisplayControlCoreTests", dependencies: ["DisplayControlCore"]),
    ],
    swiftLanguageModes: [.v5]
)
