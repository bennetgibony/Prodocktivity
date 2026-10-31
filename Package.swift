// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ArcSidebar",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(name: "ArcSidebar", path: "Sources/ArcSidebar"),
        // Run with scripts/test.sh (it points the compiler at the Testing framework).
        .testTarget(name: "ArcSidebarTests", dependencies: ["ArcSidebar"], path: "Tests/ArcSidebarTests"),
    ]
)
