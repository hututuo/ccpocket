// swift-tools-version:5.9
// Test-only SwiftPM manifest. The menubar app itself builds via
// CCPocketMenubar.xcodeproj (xcodegen/project.yml); this package exists so
// `swift test` can exercise self-contained service logic without an Xcode
// test target.
import PackageDescription

let package = Package(
    name: "CCPocketMenubarTestHarness",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ProcessRunnerKit",
            path: "CCPocketMenubar/Services",
            sources: ["ProcessRunner.swift"]
        ),
        .testTarget(
            name: "ProcessRunnerTests",
            dependencies: ["ProcessRunnerKit"],
            path: "Tests/ProcessRunnerTests"
        ),
    ]
)
