// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CoreSecurity",
    platforms: [
        .iOS(.v18),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "CoreSecurity",
            targets: ["CoreSecurity"]
        ),
    ],
    targets: [
        .target(
            name: "CoreSecurity"
        ),
        .testTarget(
            name: "CoreSecurityTests",
            dependencies: ["CoreSecurity"]
        ),
    ]
)
