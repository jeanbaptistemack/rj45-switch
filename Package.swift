// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "RJ45Switch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RJ45Switch",
            path: "Sources/RJ45Switch",
            linkerSettings: [
                .linkedFramework("CoreWLAN"),
                .linkedFramework("SystemConfiguration"),
            ]
        )
    ]
)
