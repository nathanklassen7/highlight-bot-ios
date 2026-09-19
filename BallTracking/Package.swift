// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BallTracking",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BallTracking", targets: ["BallTracking"]),
        .executable(name: "balltrack-lab", targets: ["balltrack-lab"]),
    ],
    targets: [
        .target(
            name: "BallTracking",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "balltrack-lab",
            dependencies: ["BallTracking"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BallTrackingTests",
            dependencies: ["BallTracking"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
