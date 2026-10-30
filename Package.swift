// swift-tools-version: 6.4
import PackageDescription

/// Upcoming-language features and checks applied to every Swift target,
/// tests included, so the library and its tests compile under one dialect.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "swift-mail-automation",
    platforms: [.macOS("27.2")],
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
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MailAutomationTests",
            dependencies: ["MailAutomation"],
            swiftSettings: swiftSettings
        ),
    ]
)
