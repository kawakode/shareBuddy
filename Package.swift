// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShareBuddy",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ShareBuddyCore", targets: ["ShareBuddyCore"]),
        .executable(name: "sharebuddy", targets: ["sharebuddy"]),
        .executable(name: "ShareBuddyApp", targets: ["ShareBuddyApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ShareBuddyCore",
            linkerSettings: [
                .linkedFramework("NetFS", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "sharebuddy",
            dependencies: [
                "ShareBuddyCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ShareBuddyApp",
            dependencies: ["ShareBuddyCore"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ShareBuddyCoreTests",
            dependencies: ["ShareBuddyCore"]
        ),
    ]
)
