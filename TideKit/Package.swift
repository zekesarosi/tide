// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TideKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TideKit", targets: ["TideKit"]),
        .executable(name: "tide-cli", targets: ["tide-cli"]),
    ],
    targets: [
        .target(name: "TideKit"),
        // Command-line harness for exercising the live pipeline (macOS/Linux).
        .executableTarget(name: "tide-cli", dependencies: ["TideKit"]),
        .testTarget(
            name: "TideKitTests",
            dependencies: ["TideKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
