// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "EffectComponents",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v8),
        .macCatalyst(.v15),
        .tvOS(.v12)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "EffectComponents",
            targets: ["EffectComponents"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/swift-mutex.git", from: "0.0.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "EffectComponents",
            dependencies: [
                .product(name: "Mutex", package: "swift-mutex"),
            ],
            swiftSettings: [
            ]
        ),
        .testTarget(
            name: "EffectComponentsTests",
            dependencies: [
                "EffectComponents",
                .product(name: "Mutex", package: "swift-mutex"),
            ],
            swiftSettings: [
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
