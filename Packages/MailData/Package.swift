// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MailData",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MailData",
            targets: ["MailData"]
        ),
    ],
    dependencies: [
        .package(path: "../MailCore"),
        .package(path: "../ProviderCore"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),
    ],
    targets: [
        .target(
            name: "MailData",
            dependencies: [
                "MailCore",
                "ProviderCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "MailDataTests",
            dependencies: ["MailData"]
        ),
    ]
)
