// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OpenUILang",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "OpenUILang", targets: ["OpenUILang"])
    ],
    targets: [
        .target(name: "OpenUILang"),
        .testTarget(name: "OpenUILangTests", dependencies: ["OpenUILang"]),
    ]
)
