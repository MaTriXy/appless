// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "OpenUILang",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "OpenUILang", targets: ["OpenUILang"]),
        // Build-only tooling: replays a differential-fuzz campaign
        // (spec/fixtures/generator/probes/gen-fuzz-corpus.mjs). Not a
        // dependency of OpenUILang or its tests.
        .executable(name: "openui-fuzz-driver", targets: ["OpenUILangFuzzDriver"]),
    ],
    targets: [
        .target(name: "OpenUILang"),
        .executableTarget(name: "OpenUILangFuzzDriver", dependencies: ["OpenUILang"]),
        .testTarget(name: "OpenUILangTests", dependencies: ["OpenUILang"]),
    ]
)
