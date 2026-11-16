// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StupidProjects",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "StupidProjects",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        )
    ]
)
