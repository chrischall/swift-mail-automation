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
        // Swift can't call variadic C functions such as `sqlite3_db_config`;
        // this shim exposes the one option the index reader needs.
        .target(
            name: "CMailSQLite",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MailAutomation",
            dependencies: [
                "CMailSQLite",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "MailAutomationTests",
            dependencies: ["MailAutomation"]
        ),
    ]
)
