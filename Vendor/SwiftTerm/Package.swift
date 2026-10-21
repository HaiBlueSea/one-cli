// swift-tools-version: 6.2
// Local macOS library slice of SwiftTerm v1.99.0 (2dad6a1).
// Vendored library-only manifest; upstream notices and modifications are documented in README.md.

import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .macOS(.v13),
        .iOS(.v14)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .executableTarget(
            name: "SwiftTermBuildInfoGenerator",
            path: "Sources/SwiftTermBuildInfoGenerator"
        ),
        .plugin(
            name: "SwiftTermBuildInfoPlugin",
            capability: .buildTool(),
            dependencies: ["SwiftTermBuildInfoGenerator"]
        ),
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: [
                "Mac/README.md",
                "Apple/Metal/Shaders.metal"
            ],
            plugins: [
                .plugin(name: "SwiftTermBuildInfoPlugin")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
