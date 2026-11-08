
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FeatureProperty",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "FeatureProperty",
            targets: ["FeatureProperty"]
        ),
    ],
    dependencies: [
        .package(path: "../CoreModel"),
        .package(path: "../CoreDesignSystem")
    ],
    targets: [
        .target(
            name: "FeatureProperty",
            dependencies: [
                .product(name: "CoreModel", package: "CoreModel"),
                .product(name: "CoreDesignSystem", package: "CoreDesignSystem")
            ]
        ),
        .testTarget(
            name: "FeaturePropertyTests",
            dependencies: ["FeatureProperty"]
        ),
    ]
)
