// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "AIETerminal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIETerminal", targets: ["AIETerminal"]),
        .executable(name: "AIEHookHelper", targets: ["AIEHookHelper"]),
        .executable(name: "AIERemoteHelper", targets: ["AIERemoteHelper"])
    ],
    dependencies: [.package(path: "Vendor/SwiftTerm")],
    targets: [
        .target(name: "AIETerminalCore"),
        .target(name: "AIETerminalRemoteCore"),
        .executableTarget(
            name: "AIETerminal",
            dependencies: [
                "AIETerminalCore", "AIETerminalRemoteCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .executableTarget(name: "AIEHookHelper", dependencies: ["AIETerminalCore"]),
        .executableTarget(name: "AIERemoteHelper", dependencies: ["AIETerminalRemoteCore"])
    ]
)
