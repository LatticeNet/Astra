// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Astra",
    platforms: [
        .iOS(.v16),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AstraCore", targets: ["AstraCore"]),
        .executable(name: "AstraCoreCheck", targets: ["AstraCoreCheck"])
    ],
    targets: [
        .target(name: "AstraCore"),
        .executableTarget(
            name: "AstraCoreCheck",
            dependencies: ["AstraCore"],
            path: "Checks/AstraCoreCheck"
        )
    ]
)
