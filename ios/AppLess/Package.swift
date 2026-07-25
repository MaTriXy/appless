// swift-tools-version: 6.1
import PackageDescription

// AppLess - the SwiftUI shell for the GenOS runtime.
//
// The package deliberately splits in two so that the whole non-visual half is
// buildable and testable on Linux CI (which has no Xcode and no SwiftUI SDK):
//
//   AppLessCore - design tokens, icon mapping, the contract schema tables and
//                 the renderer registry. Pure Swift + Foundation, NO SwiftUI.
//   AppLessUI   - the SwiftUI renderers, shell and App entry point. Every file
//                 is wrapped in `#if canImport(SwiftUI)`, so on Linux the
//                 target compiles to an empty module instead of failing.
//
// `swift build` / `swift test` therefore succeed on Linux; the SwiftUI half is
// compiled by macOS CI and by Xcode.
let package = Package(
    name: "AppLess",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        .library(name: "AppLessCore", targets: ["AppLessCore"]),
        .library(name: "AppLessUI", targets: ["AppLessUI"]),
    ],
    dependencies: [
        .package(path: "../Packages/OpenUILang"),
        .package(path: "../Packages/GenOSCore"),
    ],
    targets: [
        .target(
            name: "AppLessCore",
            dependencies: [
                .product(name: "OpenUILang", package: "OpenUILang"),
                .product(name: "GenOSCore", package: "GenOSCore"),
            ]
        ),
        .target(
            name: "AppLessUI",
            dependencies: [
                "AppLessCore",
                .product(name: "OpenUILang", package: "OpenUILang"),
                .product(name: "GenOSCore", package: "GenOSCore"),
            ]
        ),
        .testTarget(
            name: "AppLessCoreTests",
            dependencies: ["AppLessCore"]
        ),
    ]
)
