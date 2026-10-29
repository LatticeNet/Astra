// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Astra",
    platforms: [
        .iOS(.v26),
        .macOS(.v26)
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
