// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PerfectNotifications",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "PerfectNotifications", targets: ["PerfectNotifications"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "PerfectNotifications",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "PerfectNotificationsTests",
            dependencies: [
                "PerfectNotifications",
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
