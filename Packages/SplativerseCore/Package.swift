// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "SplativerseCore", platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [.library(name: "SplativerseCore", targets: ["SplativerseCore"])],
    targets: [.target(name: "SplativerseCore"), .testTarget(name: "SplativerseCoreTests", dependencies: ["SplativerseCore"])],
    swiftLanguageModes: [.v6]
)
