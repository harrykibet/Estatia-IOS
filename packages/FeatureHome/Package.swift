// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FeatureHome",
    platforms: [
        .iOS(.v18),
        .macOS(.v15)
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
                .product(name: "CorePlayerEngine", package: "coreplayerengine"),
                .product(name: "CorePlayerUI", package: "coreplayerui")
            ],
            exclude: [
                "Views/HomeRouteView.swift",
                "Views/HomeScreenView.swift",
                "Views/ErrorStateView.swift",
                "Views/EmptyStateView.swift",
                "Views/LoadingStateView.swift",
                "Views/HomeContentPreviewView.swift",
                "Views/HomeEmptyPreviewView.swift",
                "Views/HomeErrorPreviewView.swift",
                "Views/HomeLoadingPreviewView.swift",
                "Views/HomeContentSwahiliPreviewView.swift"
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
