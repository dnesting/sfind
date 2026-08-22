// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sfind",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "sfind", targets: ["sfind"])
    ],
    targets: [
        .executableTarget(name: "sfind", dependencies: ["SFindCore"]),
        .target(name: "SFindCore"),
        .testTarget(name: "SFindCoreTests", dependencies: ["SFindCore"]),
        .testTarget(name: "ParityTests", dependencies: ["SFindCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["SFindCore"]),
    ]
)
