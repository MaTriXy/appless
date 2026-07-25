// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GenOSCore",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "GenOSCore", targets: ["GenOSCore"])
    ],
    targets: [
        .target(name: "GenOSCore"),
        .testTarget(name: "GenOSCoreTests", dependencies: ["GenOSCore"]),
    ]
)
