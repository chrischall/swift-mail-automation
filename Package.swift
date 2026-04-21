// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-mail-automation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MailAutomation", targets: ["MailAutomation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "MailAutomation",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "MailAutomationTests",
            dependencies: ["MailAutomation"]
        ),
    ]
)
