// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TideKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TideKit", targets: ["TideKit"]),
        .executable(name: "tide-cli", targets: ["tide-cli"]),
        .executable(name: "tide-analyze", targets: ["tide-analyze"]),
    ],
    targets: [
        .target(name: "TideKit"),
        // Command-line harness for exercising the live pipeline (macOS/Linux).
        .executableTarget(name: "tide-cli", dependencies: ["TideKit"]),
        // Retrospective analysis: observed vs predicted, surge attribution, rolling hindcasts.
        .executableTarget(name: "tide-analyze", dependencies: ["TideKit"]),
        .testTarget(
            name: "TideKitTests",
            dependencies: ["TideKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
