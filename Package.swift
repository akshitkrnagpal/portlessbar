// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortlessBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PortlessBar", targets: ["PortlessBar"])],
    targets: [
        .target(name: "PortlessSystem"),
        .executableTarget(name: "PortlessBar", dependencies: ["PortlessSystem"]),
        .testTarget(name: "PortlessBarTests", dependencies: ["PortlessBar"])
    ]
)
