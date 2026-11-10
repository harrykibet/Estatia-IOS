// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FeatureHome",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(name: "FeatureHome", targets: ["FeatureHome"]),
    ],
    dependencies: [
        .package(path: "../CoreDesignSystem"),
        .package(path: "../CoreAppData"),
        .package(path: "../CoreModel"),
        .package(path: "../CorePlayerEngine"),
        .package(path: "../CorePlayerUI")
    ],
    targets: [
        .target(
            name: "FeatureHome",
            dependencies: [
                .product(name: "CoreDesignSystem", package: "CoreDesignSystem"),
                .product(name: "CoreAppData", package: "CoreAppData"),
                .product(name: "CoreModel", package: "CoreModel"),
                .product(name: "CorePlayerEngine", package: "coreplayerengine"),
                .product(name: "CorePlayerUI", package: "coreplayerui")
            ]
        ),
        .testTarget(
            name: "FeatureHomeTests",
            dependencies: [
                "FeatureHome",
                .product(name: "CoreModel", package: "CoreModel")
            ]
        ),
    ]
)
