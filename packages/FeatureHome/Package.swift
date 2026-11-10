// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FeatureHome",
    platforms: [
        .iOS(.v18),
        .macOS(.v13)
    ],
    products: [
        .library(name: "FeatureHome", targets: ["FeatureHome"]),
    ],
    dependencies: [
        .package(path: "../CoreAppData"),
        .package(path: "../CoreModel"),
        .package(path: "../CorePlayerEngine"),
        .package(path: "../CorePlayerUI")
    ],
    targets: [
        .target(
            name: "FeatureHome",
            dependencies: [
                .product(name: "CoreAppData", package: "CoreAppData"),
                .product(name: "CoreModel", package: "CoreModel"),
                .product(name: "CorePlayerEngine", package: "CorePlayerEngine"),
                .product(name: "CorePlayerUI", package: "CorePlayerUI")
            ],
            exclude: ["Views"]
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
