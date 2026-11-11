// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShareMan",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ShareManCore", targets: ["ShareManCore"]),
        .executable(name: "shareman", targets: ["shareman"]),
        .executable(name: "ShareManApp", targets: ["ShareManApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "ShareManCore",
            linkerSettings: [
                .linkedFramework("NetFS", .when(platforms: [.macOS])),
            ]
        ),
        .executableTarget(
            name: "shareman",
            dependencies: [
                "ShareManCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ShareManApp",
            dependencies: ["ShareManCore"],
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ShareManCoreTests",
            dependencies: ["ShareManCore"]
        ),
    ]
)
