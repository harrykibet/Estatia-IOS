// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CorePlayerEngine",
    platforms: [
        .iOS(.v18),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CorePlayerEngine",
            targets: ["CorePlayerEngine"]
        ),
    ],
    dependencies: [
        .package(path: "../CoreAnalytics")
    ],
    targets: [
        .target(
            name: "CorePlayerEngine",
            dependencies: [
                .product(name: "CoreAnalytics", package: "coreanalytics")
            ]
        ),
        .testTarget(
            name: "CorePlayerEngineTests",
            dependencies: [
                "CorePlayerEngine",
                .product(name: "CoreAnalytics", package: "coreanalytics")
            ]
        ),
    ]
)
