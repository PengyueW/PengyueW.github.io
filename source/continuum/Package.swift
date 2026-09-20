// swift-tools-version:5.8
// Works with `swift build` on machines with full Xcode. On Command Line
// Tools-only machines SwiftPM fails with "unable to lookup item
// 'PlatformPath'" — use ./build.sh, which compiles the same module layout
// with bare swiftc.
import PackageDescription

let package = Package(
    name: "Continuum",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CacheCleanKit"),
        .target(name: "DiskScopeKit"),
        .target(name: "MacScanKit"),
        .executableTarget(
            name: "Continuum",
            dependencies: ["CacheCleanKit", "DiskScopeKit", "MacScanKit"]),
    ]
)
