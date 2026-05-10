// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Crypta",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Crypta", targets: ["Crypta"])
    ],
    targets: [
        .executableTarget(
            name: "Crypta",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Security")
            ]
        )
    ]
)
