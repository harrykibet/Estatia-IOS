// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FeatureSettings",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "FeatureSettings",
            targets: ["FeatureSettings"]
        ),
    ],
    dependencies: [
        .package(path: "../CoreAppData"),
        .package(path: "../CoreDesignSystem")
    ],
    targets: [
        .target(
            name: "FeatureSettings",
            dependencies: [
                .product(name: "CoreAppData", package: "CoreAppData"),
                .product(name: "CoreDesignSystem", package: "CoreDesignSystem")
            ]
        ),
        .testTarget(
            name: "FeatureSettingsTests",
            dependencies: ["FeatureSettings"]
        ),
    ]
)
