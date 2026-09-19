// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HighlightCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HighlightCore", targets: ["HighlightCore"]),
    ],
    targets: [
        .target(
            name: "HighlightCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "HighlightCoreTests",
            dependencies: ["HighlightCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
