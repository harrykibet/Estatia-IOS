// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CorePlayerUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "CorePlayerUI",
            targets: ["CorePlayerUI"]
        ),
    ],
    dependencies: [
        .package(path: "../CorePlayerEngine")
    ],
    targets: [
        .target(
            name: "CorePlayerUI",
            dependencies: [
                .product(
                    name: "CorePlayerEngine",
                    package: "coreplayerengine"
                )
            ]
        ),
        .testTarget(
            name: "CorePlayerUITests",
            dependencies: [
                "CorePlayerUI",
                .product(
                    name: "CorePlayerEngine",
                    package: "coreplayerengine"
                )
            ]
        ),
    ]
)
