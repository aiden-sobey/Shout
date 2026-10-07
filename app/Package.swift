// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Shout",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable lives in ShoutCore; the executable is a thin entry point.
        .target(name: "ShoutCore", path: "Sources/ShoutCore"),
        .executableTarget(name: "Shout", dependencies: ["ShoutCore"], path: "Sources/Shout"),
        .testTarget(name: "ShoutTests", dependencies: ["ShoutCore"], path: "Tests/ShoutTests"),
    ]
)
