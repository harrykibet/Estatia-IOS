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
        .package(path: "../CoreAppData")
    ],
    targets: [
        .target(
            name: "FeatureHome",
            dependencies: [
                .product(name: "CoreDesignSystem", package: "CoreDesignSystem"),
                .product(name: "CoreAppData", package: "CoreAppData")
            ]
        ),
        .testTarget(
            name: "FeatureHomeTests",
            dependencies: ["FeatureHome"]
        ),
    ]
)
