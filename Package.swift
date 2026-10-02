// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PortlessBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PortlessBar", targets: ["PortlessBar"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "PortlessSystem"),
        .executableTarget(name: "PortlessBar", dependencies: ["PortlessSystem", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "PortlessBarTests", dependencies: ["PortlessBar"])
    ]
)
