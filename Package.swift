// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppleMailKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppleMailKit", targets: ["AppleMailKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AppleMailKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "AppleMailKitTests",
            dependencies: ["AppleMailKit"]
        ),
    ]
)
