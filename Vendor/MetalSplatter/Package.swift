// swift-tools-version: 6.1
// Vendored at 464eb37c55d90d7362a79120fdf8b50d4ae03296.
// App-only manifest: local SPZ dependency, no converter/argument-parser dependency.
import PackageDescription
let package = Package(
    name: "MetalSplatter", platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "MetalSplatter", targets: ["MetalSplatter"]),
        .library(name: "SplatIO", targets: ["SplatIO"])
    ],
    dependencies: [.package(path: "../spz-swift")],
    targets: [
        .target(name: "PLYIO", path: "PLYIO", sources: ["Sources"]),
        .target(name: "SplatIO", dependencies: ["PLYIO", .product(name: "spz", package: "spz-swift")], path: "SplatIO", sources: ["Sources"]),
        .testTarget(name: "PLYIOTests", dependencies: ["PLYIO"], path: "PLYIO", sources: ["Tests"], resources: [.copy("TestData")]),
        .testTarget(name: "SplatIOTests", dependencies: ["SplatIO"], path: "SplatIO", sources: ["Tests"], resources: [.copy("TestData")]),
        .testTarget(name: "MetalSplatterTests", dependencies: ["MetalSplatter", "SplatIO"], path: "SplativerseTests"),
        // A root folder named Resources makes this flat visionOS bundle invalid for signing.
        .target(name: "MetalSplatter", dependencies: ["SplatIO"], path: "MetalSplatter", sources: ["Sources"], resources: [.copy("ShaderSources")])
    ], swiftLanguageModes: [.v6]
)
