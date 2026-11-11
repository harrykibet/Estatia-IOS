// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CoreAnalytics",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "CoreAnalytics",
            targets: ["CoreAnalytics"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/firebase/firebase-ios-sdk.git",
            from: "12.0.0"
        )
    ],
    targets: [
        .target(
            name: "CoreAnalytics",
            dependencies: [
                .product(name: "FirebaseAnalytics", package: "firebase-ios-sdk"),
                .product(name: "FirebasePerformance", package: "firebase-ios-sdk")
            ]
        ),
        .testTarget(
            name: "CoreAnalyticsTests",
            dependencies: ["CoreAnalytics"]
        ),
    ]
)
