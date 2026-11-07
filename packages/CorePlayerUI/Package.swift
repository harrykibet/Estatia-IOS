// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CorePlayerUI",
    platforms: [
        .iOS(.v18)
    ],
    dependencies: [
        .package(path: "../CorePlayerEngine")
    ],
    products: [
        .library(
            name: "CorePlayerUI",
            targets: ["CorePlayerUI"]
        ),
    ],
    targets: [
        .target(
            name: "CorePlayerUI",
            dependencies: [
                .product(
                    name: "CorePlayerEngine",
                    package: "CorePlayerEngine"
                )
            ]
        ),
        .testTarget(
            name: "CorePlayerUITests",
            dependencies: ["CorePlayerUI"]
        ),
    ]
)
