// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NFSIVBuilder",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "BuilderCore"),
        .executableTarget(name: "NFSIVBuilder", dependencies: ["BuilderCore"]),
        .testTarget(name: "BuilderCoreTests", dependencies: ["BuilderCore"]),
    ]
)
