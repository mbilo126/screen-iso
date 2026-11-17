// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenISO",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ScreenISO", targets: ["ScreenISO"])
    ],
    targets: [
        .target(name: "ScreenISOCore"),
        .executableTarget(name: "ScreenISO", dependencies: ["ScreenISOCore"]),
        .testTarget(name: "ScreenISOCoreTests", dependencies: ["ScreenISOCore"]),
        .testTarget(name: "ScreenISOTests", dependencies: ["ScreenISO", "ScreenISOCore"]),
    ]
)
